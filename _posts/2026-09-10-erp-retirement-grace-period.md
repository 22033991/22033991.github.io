---
layout: post
title: "원천 데이터에 공백이 생겼을 때 — 유예 기간을 내부 스냅샷으로 메우기"
date: 2026-09-10 22:00:00 +0900
categories: [Backend, Integration]
tags: [HR System, Organization, Data Migration, Oracle]
excerpt: "인사시스템이 더 이상 보내지 않는 겸직 정보를, 본직 교체 전 스냅샷과 명시적인 만료 조건으로 유예 기간 동안 유지했다."
---

다법인 구조의 그룹사였다. 한 사람이 여러 법인에 겸직을 가지면서 겸직 수만큼 계정을 쓰고 있었다. 그룹웨어만 운영할 때는 그냥 뒀는데, Teams 연동이 붙으면서 계정마다 비용이 나가기 시작했다. 결국 로그인 계정은 한 사람당 하나로 합치고, 법인별 소속은 겸직 정보로만 관리해야 했다.

문제는 계정을 합치는 걸로 끝나지 않았다는 것이다. 기존 법인에 진행 중인 업무가 남은 사용자는 과거 소속과 결재 이력을 유예 기간 동안 계속 볼 수 있어야 했다. 그런데 인사시스템은 이런 사용자를 바로 퇴사자로 내려주지 않았고, 본직이 새 법인으로 바뀌고 나면 기존 겸직 정보도 더는 조직도 데이터로 주지 않았다.

그룹웨어 화면에는 계속 보여야 하는데 인사시스템의 현재 데이터에는 없는 상태가 생긴 것이다.

## 수동 수정으로 해결할 수 없는 문제

처음엔 그룹웨어 데이터를 SQL로 직접 정리할까 싶었다. 그런데 그렇게 고쳐놔도 다음 조직도 동기화 때 인사시스템 데이터로 다시 덮어써질 수 있었고, 같은 인사 이동이 생길 때마다 사람이 계속 붙어야 했다.

필요한 건 일회성 수정이 아니라 반복해서 돌아가는 규칙이었다. 본직이 다른 법인으로 옮겨가도 기존 법인 업무가 남아 있으면, 로그인 계정은 하나로 합치되 기존 소속은 유예 기간 동안 겸직으로 유지하고, 유예가 끝나면 그 소속을 지우는 규칙.

인사시스템은 이걸 위해 퇴직예외 정보를 내려줬다. 법인 코드, 사번, 유예 시작일과 종료일, 상태 코드가 주요 값이었다.

```sql
SELECT company_code,
       employee_no,
       grace_start_at,
       grace_end_at,
       status
FROM   hr_retirement_exception
WHERE  company_code = :companyCode
```

유예 시작일도 같이 받았지만, 지금 유예 대상인지를 가르는 핵심 판정은 상태와 종료일이었다.

```sql
status = 9
AND grace_end_at > SYSDATE
```

이 조건은 인사시스템이 유예 시작 이후에 대상 데이터를 준다는 걸 전제로 한다. 그래서 시작 전 데이터가 미리 넘어오는지, 종료일을 포함하는지도 같이 확인했다. 종료일이 날짜 단위인지 시각 단위인지에 따라 마지막 날 자정에 예상보다 일찍 만료될 수 있어서였다. 이 판정 하나가 결국 조직도 연동 전체가 공유하는 업무 규칙이 됐다.

## 같은 사람인데 사번이 달라졌다

제일 까다로운 건 본직이 다른 법인으로 완전히 넘어가는 순간이었다.

기존 조직도 연동은 대상을 신규 사용자(`I`)와 기존 사용자 수정(`U`), 딱 두 가지로만 나눴다. 그런데 법인이 바뀌면 같은 사람한테 새 사번이 붙는다. 새 사번만 보면 신규 사용자 같지만, 실제로는 기존 계정과 이력에 새 본직을 이어붙여야 하는 사람이다.

이걸 신규로 넘기면 새 계정이 생기면서 기존 결재 이력과 권한 연결이 끊긴다. 그렇다고 기존 사번으로 수정하려 해도, 인사시스템에서 받은 사번이 이미 달라져서 대상 자체를 못 찾는다.

그래서 `C`, 본직 교체라는 처리 유형을 따로 만들었다.

```java
public static final String JOB_MODE_CHANGE_PRIMARY = "C";
```

판정에는 사번보다 상위에 있는 개인 공통키를 썼다.

```sql
WHEN EXISTS (
    SELECT 1
    FROM   gw_user old_user
    WHERE  old_user.person_key = hr_user.person_key
      AND  old_user.employee_no <> hr_user.employee_no
      AND  EXISTS (
          SELECT 1
          FROM   hr_retirement_exception exception_user
          WHERE  exception_user.company_code = old_user.company_code
            AND  exception_user.employee_no = old_user.employee_no
            AND  exception_user.status = 9
            AND  exception_user.grace_end_at > SYSDATE
      )
) THEN 'C'
```

개인 공통키는 같은데 사번이 달라졌고, 기존 법인 사번이 퇴직 유예 중이면 신규 입사가 아니라 본직 교체다. 다법인 환경에서는 사번만으로 사람을 특정할 수 없었고, 유예 정보도 다른 법인의 같은 사번과 엉키지 않게 법인 코드와 사번을 같이 봐야 했다.

## 일반 경로와 본직 교체 경로를 분리했다

본직 교체 대상이 일반 사용자 갱신 로직까지 타면, 처리 순서에 따라 사번이나 로그인 ID가 먼저 바뀌어버린다. 그러면 기존 소속을 보존하기도 전에 필요한 정보를 잃는다.

그래서 유예 여부로 처리 경로를 갈랐다. 유예 대상이 아닌 일반 사용자는 기존 `I`·`U` 흐름을 그대로 타고, 일반 겸직 갱신도 인사시스템 겸직 정보를 그대로 반영한다. 유예 대상일 때만 본직 교체 경로로 보내서, 기존 본직을 보존한 뒤에 새 본직을 반영했다.

본직 교체에서는 사번 대신 그룹웨어 내부의 안정적인 사용자 식별자로 기존 계정을 찾았다. 바뀔 예정인 사번을 검색 조건으로 쓰면, 정작 업데이트할 원본 계정을 못 찾기 때문이다.

## 덮어쓰기 전에 기존 본직을 스냅샷으로 남겼다

본직 정보를 새 법인 값으로 바꾸기 전에, 기존 데이터를 먼저 읽어서 겸직 레코드로 저장해뒀다.

```java
private UserAddJob createPreviousJobSnapshot(LinkUser incomingUser)
        throws BusinessException {

    User currentUser = userDAO.findByUserId(incomingUser.getUserId());

    UserAddJob previousJob = new UserAddJob();
    previousJob.setJobType(ADD_JOB);
    previousJob.setEmployeeNo(currentUser.getEmployeeNo());
    previousJob.setLoginId(currentUser.getLoginId());
    previousJob.setCompanyId(currentUser.getCompanyId());
    previousJob.setDepartmentId(currentUser.getDepartmentId());

    return previousJob;
}
```

그다음에 기존 계정의 본직 정보를 새 법인의 사번, 로그인 ID, 회사와 부서 정보로 교체했다.

옛 계정을 살아있는 사용자로 남겨둔 건 아니다. 로그인되는 계정은 새 본직 계정 하나뿐이고, 기존 사번과 로그인 ID는 과거 결재 이력과 유예 기간 조직도 표시를 이어주는 겸직 정보로만 남겼다.

여기서는 순서가 중요했다. 기존 본직을 먼저 조회해서 겸직으로 저장해두고, 그다음에 새 법인 정보를 본직에 반영해야 한다. 본직부터 덮어쓰면 옛 사번과 소속을 되살릴 방법이 없다. 스냅샷 생성과 본직 교체도 하나의 업무 단위로 묶어서, 한쪽만 반영되는 상태가 안 생기게 했다.

## 인사시스템이 보내지 않는 데이터를 내부 정보로 복원했다

본직 교체가 끝나고 나니 또 다른 문제가 있었다. 인사시스템 입장에서는 이 사람이 이미 새 법인 본직으로 넘어갔으니, 기존 법인 소속을 일반 사용자로도 겸직으로도 안 보내준다.

그런데 그룹웨어는 퇴직 유예가 끝날 때까지 기존 법인 소속을 조직도와 결재선에 계속 보여줘야 했다.

그래서 겸직 목록을 만들 때, 인사시스템이 지금 주는 겸직 정보에 본직 교체 전에 저장해둔 스냅샷을 합쳤다. 공개 가능한 형태로 단순화한 조회는 이렇다.

```sql
SELECT /* 인사시스템이 제공하는 현재 겸직 */
       ...
FROM   hr_multi_job

UNION

SELECT /* 유예 기간 동안 복원할 기존 소속 */
       ...
FROM   gw_user previous_user
JOIN   gw_user_add_job previous_job
  ON   previous_job.user_id = previous_user.user_id
WHERE  NOT EXISTS (
           SELECT 1
           FROM hr_user current_user
           WHERE current_user.company_code = previous_user.company_code
             AND current_user.employee_no = previous_user.employee_no
       )
  AND  NOT EXISTS (
           SELECT 1
           FROM hr_multi_job current_job
           WHERE current_job.company_code = previous_user.company_code
             AND current_job.employee_no = previous_user.employee_no
       )
  AND  EXISTS (
           SELECT 1
           FROM hr_retirement_exception exception_user
           WHERE exception_user.company_code = previous_user.company_code
             AND exception_user.employee_no = previous_user.employee_no
             AND exception_user.status = 9
             AND exception_user.grace_end_at > SYSDATE
       )
```

물론 인사시스템 목록에 없다고 아무나 복원하는 건 아니다. 인사시스템의 현재 사용자 목록과 겸직 목록 양쪽에 다 없고, 그룹웨어에 본직 교체 전 저장해둔 소속이 남아 있고, 그 법인·사번이 지금 퇴직 유예 중일 때만 내부 스냅샷을 겸직 소스로 썼다.

없는 데이터를 지어낸 게 아니라, 과거에 받아둔 사실과 인사시스템이 준 유예 상태를 조합해서 한시적인 파생 데이터를 만든 것이다.

## 유예 데이터의 생성보다 종료가 중요했다

임시 데이터를 만들 땐 언제 지울지도 같이 정해야 했다. 유예가 끝났는데 옛 소속이 남아 있으면, 퇴직자가 조직도나 결재선에 계속 뜨게 된다.

그래서 유예 종료를 세 군데에서 처리했다. 겸직 소스 조회에서 만료된 스냅샷이 다시 들어오는 걸 막았고, `jobmode` 판정에서 본직 교체 경로를 끝내고 일반 처리로 돌려보냈고, 정리 배치가 이미 저장된 유예 겸직 레코드를 지웠다.

세 조건은 같은 일을 세 번 하는 게 아니라 역할이 다 달랐다. 조회 조건은 재유입을 막고, `jobmode`는 특수 처리를 할지 말지 정하고, 정리 배치는 남은 데이터를 실제로 지운다. 생성 조건, 유지 조건, 종료 조건을 따로따로 심어놔야 임시 데이터가 영구 데이터처럼 눌러앉는 걸 막을 수 있었다.

## 원천 데이터가 없다고 업무 상태까지 사라지는 것은 아니다

원천 시스템이 안 보내주는 데이터라고 해서 우리 마음대로 만들어도 되는 건 당연히 아니다.

다만 인사시스템의 현재 데이터만으로는 표현이 안 되는 과도기 상태가 분명히 있었고, 그럴 때는 과거에 받아서 저장해둔 데이터와 인사시스템이 명시적으로 준 유효 기간을 근거로 삼을 수 있었다. 그래서 이 스냅샷 로직에는 어떤 원천 데이터에서 파생됐는지, 어떤 키로 같은 사람과 소속을 식별하는지, 언제부터 언제까지 유효한지, 반복 실행해도 중복되지 않는지, 만료 후 어떻게 제거되는지를 전부 명시해뒀다.

솔직히 제일 오래 걸린 건 데이터를 만드는 코드가 아니었다. 시스템마다 다른 식별자를 어떻게 이어붙일지, 인사시스템이 표현 못 하는 유예 상태를 그룹웨어 안에서 끝까지 어떻게 관리할지 정하는 쪽이 훨씬 어려웠다.