---
layout: post
title: "비밀번호 재설정을 위한 외부 본인인증 연동"
date: 2026-09-08 22:00:00 +0900
categories: [Backend, Security]
tags: [Authentication, Java, Integration]
excerpt: "본인 확인 없이 초기화할 수 없는 비밀번호 재설정 기능을, 외부 인증 서비스와 요청/결과 조회 두 단계로 나눠 연동한 기록."
---

금융권 고객사의 그룹웨어에 비밀번호 재설정 기능을 개발했다.

비밀번호를 잊은 사용자가 별도의 확인 없이 초기화를 요청할 수는 없었다. 

먼저 로그인 ID와 등록된 휴대폰 번호가 일치하는 사용자를 찾고, 외부 인증 서비스를 통한 본인인증이 완료된 경우에만 비밀번호를 재설정할 수 있게 해야 했다.

## 인증 요청과 결과 조회가 분리된 API

외부 인증 서비스는 요청과 동시에 성공 여부를 반환하지 않았다. 사용자가 본인 명의의 인증 채널에서 요청을 확인하고 승인해야 했기 때문이다.

그래서 전체 흐름은 로그인 ID와 휴대폰 번호를 확인해 사용자를 특정하고, 외부 인증을 요청하고, 사용자가 승인하면, 그 결과를 조회해 비밀번호 재설정을 허용하는 순서로 나뉘었다.

첫 번째 단계에서는 로그인 ID와 휴대폰 번호가 일치하는 사용자를 조회한 뒤 외부 서비스에 인증 세션 생성을 요청한다. (블로그 올라오는 코드는 모두 익명화하거나 , 다른 코드로 대치한 것!)

```java
public void requestVerification(FormData formData)
        throws BusinessException, JSONException {

    String contactNumber =
        formData.getString("contactNumber", "");

    String encryptedContact = isLocalEnv
        ? contactNumber
        : encryptService.encrypt(contactNumber);

    formData.setObject(
        "encryptedContact",
        encryptedContact
    );

    String userId =
        userDAO.findUserByLoginIdAndContact(formData);

    if (!StringUtils.isEmpty(userId)) {
        UserVO user = userService.getUser(userId);

        JSONObject response =
            externalAuthService.requestSession(
                user.getEmployeeId()
            );

        if (isSuccess(response)) {
            JSONObject data =
                response.getJSONObject("data");

            sessionKey =
                data.getString("sessionKey");

            sessionTimeout =
                data.getInt("sessionTimeout");
        }
    }
}
```

사용자를 찾았다는 이유만으로 비밀번호를 변경할 수 있는 것은 아니다. 이 단계에서는 외부 인증을 시작하고, 인증 요청을 식별할 키와 유효 시간을 전달받을 뿐이다.

실제 비밀번호 재설정 권한은 두 번째 단계에서 인증 완료 여부를 확인한 뒤에 부여된다.

## 호출하는 쪽과 호출받는 쪽을 함께 만들었다

외부 서비스와 직접 연결할 수 없는 상태에서도 화면 개발을 진행해야 했다. 그래서 예상 응답 데이터를 먼저 정의하고, 인증 서비스가 그 값을 반환했다고 가정해 화면과 결과 조회 기능을 함께 구현했다.

같이 일하던 선배 개발자의 조언으로 시작한 방식이었다. 호출 코드만 먼저 작성할 때는 정상 응답에 집중하기 쉽다. 반대로 응답을 받아 처리하는 코드까지 함께 만드니, 세션키가 없거나 잘못됐을 때 어떻게 처리할지, 인증 시간이 만료되면 화면 상태를 어떻게 되돌릴지, 요청은 성공했지만 사용자가 인증하지 않으면 어떻게 할지, 같은 인증 결과를 여러 번 조회하면 어떻게 처리할지 같은 질문들을 더 일찍 발견할 수 있었다.

응답을 소비하는 입장에서 API를 바라보니 정상 흐름 외에 필요한 상태와 예외가 더 구체적으로 보였다.

## 인증 결과는 별도 요청으로 확인한다

인증 요청이 성공하면 사용자는 외부 인증 채널에서 승인 절차를 진행한다. 이후 그룹웨어 화면에서 '결과 확인' 버튼을 누르면 서버가 외부 서비스에 인증 결과를 조회한다.

```java
public void checkVerificationResult(FormData formData)
        throws BusinessException, JSONException {

    String sessionKey =
        formData.getString("sessionKey");

    String verificationKey =
        formData.getString("verificationKey");

    JSONObject response =
        externalAuthService.checkResult(
            verificationKey,
            sessionKey
        );

    if (isSuccess(response)) {
        result = true;
    }
}
```

외부 인증이 끝날 때까지 서버 요청을 계속 열어두지 않고, 인증 시작과 결과 확인을 서로 다른 요청으로 분리했다. 사용자의 승인이 언제 끝날지 알 수 없는 상황에서 서버 커넥션과 처리 스레드를 장시간 점유하지 않기 위한 구조였다.

사용자가 버튼을 눌렀을 때 한 번씩 결과를 조회했으므로, 엄밀히 말하면 일정 간격으로 자동 호출하는 폴링보다는 사용자 액션 기반의 상태 조회에 가까웠다.

## 세션키는 인증 결과를 연결하는 식별자다

인증 요청에서 받은 sessionKey는 결과 조회 요청을 처음 요청과 연결하는 데 사용했다.

```javascript
success: function (data) {
    if (
        data.result === "true" &&
        data.verificationKey !== ""
    ) {
        $("#sessionKey").val(data.sessionKey);
        $("#verificationKey").val(
            data.verificationKey
        );

        startCountdown(data.time);
    }
}
```

다만 hidden 필드에 저장됐다는 이유로 이 값이 안전해지는 것은 아니다. 브라우저에서 서버로 들어오는 값은 hidden 필드를 포함해 사용자가 변경할 수 있기 때문이다.

그래서 세션키는 본인인증이 완료됐다는 증거가 아니라, 어떤 인증 요청의 결과를 조회할지 지정하는 식별자로만 썼다. 실제 인증 성공 여부는 서버가 외부 서비스에 다시 확인한 결과를 기준으로 판단했다.

세션키는 어떤 요청의 결과인지 구분하는 식별자일 뿐이었고, 그 식별자가 가리키는 사용자와 지금 비밀번호를 바꾸려는 사용자가 같은지는 서버가 따로 확인했다.

세션의 재사용 방지나 만료 검증까지 우리 쪽에서 다시 구현하지는 않았다. 세션키를 발급하고 관리하는 주체가 외부 인증 서비스였던 만큼, 이미 승인된 세션을 다시 쓰거나 만료된 세션으로 결과를 조회하면 외부 서비스가 실패 응답을 주는 구조였고, 우리는 그 응답을 그대로 신뢰했다. 대신 비밀번호 변경이 완료된 뒤에는 그 계정으로 로그인돼 있던 기존 세션을 모두 무효화해서, 변경 전 세션으로 계속 접근할 수 있는 경로는 남기지 않았다.

## 클라이언트 타이머는 UX를 위한 장치다

인증 요청이 성공하면 화면을 인증 대기 상태로 전환했다.

```javascript
function startCountdown(time) {
    let remaining = Math.floor(time / 1000);

    $("#requestBtn")
        .hide()
        .prop("disabled", true);

    $("#resultBtn")
        .show()
        .prop("disabled", false);

    $("#loginId").prop("readonly", true);
    $("#contactNumber").prop("readonly", true);

    const timerId = setInterval(() => {
        const min = Math.floor(remaining / 60);
        const sec = remaining % 60;

        $("#timer").text(
            `${String(min).padStart(2, "0")}:` +
            `${String(sec).padStart(2, "0")}`
        );

        remaining--;

        if (remaining < 0) {
            clearInterval(timerId);
            $("#timer").text("TIME OUT");

            $("#requestBtn")
                .show()
                .prop("disabled", false);

            $("#resultBtn")
                .hide()
                .prop("disabled", true);
        }
    }, 1000);
}
```

인증을 기다리는 동안 로그인 ID와 휴대폰 번호를 변경하지 못하게 하고, 남은 시간을 화면에 표시했다. 시간이 지나면 처음 상태로 돌아가 다시 인증을 요청할 수 있게 했다.

하지만 클라이언트의 카운트다운이 인증 만료를 보장하는 것은 아니었다. 사용자는 브라우저의 값을 변경하거나 자바스크립트 실행을 우회할 수 있다. 화면의 타이머는 남은 시간을 알려주는 UX 장치였고, 실제 유효성은 결과 조회 시 외부 인증 서비스가 판단한 만료 상태를 따랐다.

## 외부 오류 코드를 내부 메시지로 변환했다

외부 인증 서비스는 실패 시 자체 resultCode를 반환했다. 이 코드를 화면에 그대로 노출하지 않고 내부 코드 테이블을 거쳐 사용자 메시지로 변환했다.

```java
String code = String.valueOf(resultCode);

CodeVO errorCode = codeService.getCode(
    AUTH_ERROR_CODE,
    code,
    locale
);

if (errorCode != null) {
    resultMessage = errorCode.getName();ss

    logger.error(
        "Verification failed. code={}, message={}",
        code,
        resultMessage
    );
}
```

이렇게 하니 외부 서비스의 코드와 사용자에게 보여줄 메시지를 분리할 수 있었다. 새로운 오류 코드가 추가되거나 안내 문구가 바뀌어도 연동 로직을 수정하지 않고 코드 테이블에서 관리할 수 있었다. 화면과 로그의 목적도 자연스럽게 나뉘었다 — 화면에는 사용자가 이해할 수 있는 다국어 메시지를 표시하고, 로그에는 장애 추적에 필요한 외부 응답 코드를 남겼다.

다만 비밀번호 재설정 화면이라 오류 메시지에도 신경 쓸 게 하나 더 있었다. "존재하지 않는 ID"와 "휴대폰 번호 불일치"를 구체적으로 나누어 보여주면 공격자가 유효한 계정을 추측할 수 있었다. 그래서 화면에는 두 경우 모두 같은 메시지만 보여주고, 실제로 어떤 사유로 실패했는지는 관리 로그에만 남겼다.

## 인증 요청을 시작하는 조건도 좁혔다

로그인 ID만 입력했다고 외부 인증 세션을 열지는 않았다. 시스템에 등록된 휴대폰 번호까지 일치해야 다음 단계로 진행할 수 있게 했다.

그렇다고 로그인 ID와 휴대폰 번호의 일치 자체가 본인인증을 의미하는 것은 아니다. 두 값은 인증 대상을 좁히기 위한 조건이었고, 실제 본인 여부는 외부 서비스에서 사용자가 승인한 결과로 확인했다. 로그인 ID와 휴대폰 번호가 일치하면 인증 대상을 특정할 뿐이고, 외부 인증 승인이 성공해야 본인 확인이 끝난 것이며, 본인 확인이 끝나야만 비밀번호 재설정을 허용했다.
