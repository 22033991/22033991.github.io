---
layout: post
title: "HWP 문서 안의 이미지는 어느 입력 필드의 값일까 — BinData와 셀을 다시 연결하기"
date: 2026-09-15 22:00:00 +0900
categories: [Backend, Document]
tags: [HWP, Java, Parsing, Mobile API]
excerpt: "HWP 문서의 셀과 BinData에 분리돼 있던 이미지 정보를, 문서 생성 규칙과 컨트롤 검증을 이용해 모바일용 JSON으로 변환했다."
---

모바일 API로 전자결재 문서를 제공하는 프로젝트였다. 결재 문서 중 일부가 한컴오피스의 웹 기안기로 작성된 것들이었는데, 모바일 앱에서 보여주려면 HWP 안의 셀과 누름틀 값을 읽어 JSON으로 바꿔야 했다.

텍스트 필드는 그래도 쉬웠다. 문제는 셀 안에 들어간 이미지였다.

라이브러리로 이미지 파일 자체는 읽을 수 있었다. 그런데 모바일 API에 필요한 건 이미지 목록이 아니었다. 이 바이너리 데이터가 어느 셀에 들어 있고 업무상 어떤 필드의 값인지, 그 연결을 되살려야 했다.

## 두 번째로 만난 HWP 이미지 문제

HWP 이미지를 다룬 건 이번이 두 번째였다.

사원 시절에는 결재 문서의 직인이 간헐적으로 사라지는 장애를 맡았다. 구축 인력이 다 퇴사한 뒤라 사내에 동작을 설명해줄 사람이 없었다. 결국 다른 팀 도움을 받아 오픈소스 라이브러리의 패치 버전을 적용해서 해결했다.

그때는 받은 패치를 적용하는 데 그쳤지만, 이번엔 문서 구조를 직접 따라가며 이미지와 필드의 관계를 찾아야 했다. 공공기관 프로젝트를 하면 HWP는 자주 만나는데, 일반적인 웹 개발에 비해 참고할 사례가 적어서 결국 샘플 문서를 직접 뜯어보는 수밖에 없었다.

## 라이브러리는 구조를 주지만 업무 의미까지 알지는 못한다

프로젝트에서는 Java 오픈소스 라이브러리인 [hwplib](https://github.com/neolord0/hwplib)으로 HWP 파일을 읽었다. 문서 정보, 본문, 표와 셀, 컨트롤, 첨부된 바이너리 데이터까지 접근할 수 있는 라이브러리다.

HWP 5.0은 한컴이 형식을 공개한 바이너리 문서 포맷이다. 문서 정보의 BinData 레코드에는 첨부 데이터의 형식과 저장 ID가 들어 있고, 실제 이미지 바이트는 파일 내부의 `BinData` 스토리지에 저장된다.

`hwplib`에서도 두 영역은 따로 노출된다.

```java
hwpFile.getDocInfo().getBinDataList();
hwpFile.getBinData().getEmbeddedBinaryDataList();
```

첫 번째 목록에는 문서가 참조하는 BinData 정보가 있고, 두 번째 목록에는 실제 파일명과 바이트 배열이 있다. 이 구조만 봐서는 결재 양식에서 쓰는 업무 필드명이 나오지 않았다.

라이브러리가 이미지를 못 읽은 게 아니었다. HWP의 저수준 구조와 우리 결재 양식의 필드 의미 사이를 애플리케이션에서 이어줘야 했다.

## 샘플 문서에서 명명 규칙을 찾았다

웹 기안기가 만든 HWP 파일 여러 개를 비교하다 보니 패턴이 보였다. 내장 이미지는 `BIN0001.png`처럼 순번이 붙은 이름으로 저장됐고, 대상 양식에서는 이미지 필드를 순회하는 순서와 BinData 순번이 일치했다. DocInfo에서 본 확장자도 실제 내장 파일의 확장자와 같았다.

이 패턴을 이용해서, 이미지 필드를 만날 때마다 예상되는 BinData 이름을 만들고 실제 바이너리 목록에서 짝을 찾았다.

```java
int imageIndex = 0;

// 셀을 순회하면서 이미지 필드를 만난 경우
if (isImageField(fieldName)) {
    BinData binInfo = hwpFile.getDocInfo()
                              .getBinDataList()
                              .get(imageIndex);

    String expectedName = buildBinDataName(
        imageIndex + 1,
        binInfo.getExtensionForEmbedding()
    );

    EmbeddedBinaryData embedded = findByExactName(
        hwpFile.getBinData().getEmbeddedBinaryDataList(),
        expectedName
    );

    if (embedded != null) {
        value = toDataUri(
            embedded.getName(),
            embedded.getData()
        );
        imageIndex++;
    }
}
```

위 코드는 핵심 흐름과 나중에 알게 된 개선점을 같이 반영해서 공개 가능한 형태로 단순화한 예시다. 당시 구현은 계산한 이름이 실제 파일명에 포함되는지만 봤다. 대상 문서에서는 잘 돌아갔지만 위험한 방식이었다. `1.png`를 부분 검색하면 `BIN0011.png`까지 걸리기 때문이다. 지금 다시 짠다면 파일명을 정규화해서 정확히 비교했을 것 같다.

## 이미지는 JSON 안에 Data URI로 넣었다

찾은 이미지 바이트는 Base64로 바꾼 뒤 Data URI 형태로 응답에 담았다.

```java
private String toDataUri(String fileName, byte[] data) {
    String mimeType = resolveMimeType(fileName);
    String encoded = Base64.getEncoder().encodeToString(data);

    return "data:" + mimeType + ";base64," + encoded;
}
```

모바일 화면에서는 이 값을 이미지의 `src`로 바로 쓸 수 있었다.

```html
<img src="data:image/png;base64,...">
```

이미지 파일을 따로 저장하고 다시 내려주는 API를 만들 필요가 없다는 게 장점이었다. 다만 Base64는 원본 바이너리보다 응답이 커지니까, 이미지가 많거나 크면 별도 파일 API에 캐시를 붙이는 쪽이 낫다. 이번엔 결재 양식 안의 작은 이미지로 범위가 제한돼 있어서 인라인으로 갔다.

당시 코드도 파일명으로 Data URI를 조립했는데, 지금 보면 MIME 타입과 파일명을 같은 값처럼 쓴 셈이다. 확장자를 보고 `image/png`, `image/jpeg`로 바꿔줬어야 했다. `data:image/BIN0001.png`는 MIME 타입이 아니니까.

## 마지막 이미지를 직인으로 단정할 수 없었다

직인 이미지는 따로 처리해야 했다. 대상 양식에서는 직인이 마지막 BinData에 저장되는 패턴이 있었지만, 직인이 없는 문서에도 다른 이미지는 있을 수 있었다.

마지막 바이너리를 무조건 직인으로 쓰면 엉뚱한 첨부 이미지가 직인 자리에 뜬다. 그래서 해당 문단에 실제 이미지 컨트롤이 있는지부터 확인했다.

```java
public static boolean hasImageControl(Paragraph paragraph) {
    for (Control control : paragraph.getControlList()) {
        if (control instanceof ControlRectangle) {
            return true;
        }

        if (control instanceof ControlPicture) {
            return true;
        }
    }

    return false;
}
```

프로젝트의 문서 생성 경로는 두 가지였다. 내부 API가 직인을 삽입하면 사각형 계열 컨트롤로 들어갔고, 한컴오피스에서 직접 삽입하면 그림 컨트롤로 들어갔다. 둘 다 확인한 뒤에만 직인 필드를 결과에 넣었다. 이 검증을 붙이고 나서야 직인 없는 문서에서 마지막 이미지가 직인으로 잘못 뜨는 문제가 사라졌다.

물론 모든 `ControlRectangle`이 이미지를 뜻하는 건 아니다. 이 판정은 우리 프로젝트의 문서 생성 방식과 샘플 파일을 보고 정한 규칙이었다. 다른 경로로 만들어진 HWP까지 다루려면 컨트롤 안의 그림 정보와 BinData 참조까지 봐야 할 것 같다.

## 순서 기반 매핑은 포맷 전체의 보장이 아니었다

이 구현의 핵심은 샘플에서 찾은 순서와 명명 규칙이었는데, 이걸 모든 HWP 문서에 통하는 공식 규칙으로 볼 수는 없었다.

문서를 다른 한컴오피스 버전으로 다시 저장하거나 이미지를 지웠다 다시 넣으면 BinData 순서가 달라질 수 있다. 이미지 필드 말고 본문 그림이 먼저 나와도 인덱스가 어긋난다. 웹 기안기가 만드는 제한된 양식 안에서만 검증된 규칙에 가까웠다.

그래서 방어 장치를 여럿 뒀다. 대상 필드와 이미지 수가 예상 범위인지 확인하고, 계산한 이름과 실제 파일명을 정확히 비교하고, 데이터를 찾았을 때만 다음 인덱스로 넘어갔다. 직인은 해당 문단의 이미지 컨트롤이 있는지 한 번 더 봤다. 매핑에 실패하면 다른 이미지를 대신 쓰지 않고 필드를 비운 채 로그를 남기게 했다.

길게 보면 그림 컨트롤이 가진 BinData 참조 ID를 직접 따라가는 쪽이 더 안전하다. 당시엔 쓰고 있던 라이브러리 버전과 문서 생성 방식 안에서 안정적으로 돌아가는 규칙을 먼저 찾아서 적용했다.

## 문서 파싱은 구조와 의미를 연결하는 작업이었다

이 작업에서 어려웠던 건 Base64 변환이나 JSON 생성이 아니었다. HWP가 주는 문서 구조를 그룹웨어의 업무 의미로 다시 이어붙이는 과정이었다.

오픈소스 라이브러리는 파일을 읽는 수단만 준다. 우리 프로젝트의 양식 규칙까지 알 리가 없다. 결국 서로 다른 경로로 만들어진 샘플 문서를 비교하면서, 반복되는 패턴과 그 패턴이 깨지는 경우를 같이 찾아야 했다.

깔끔한 추상화 하나로 모든 문서를 처리하는 것보다는, 이 규칙이 어디까지 통하는지를 분명히 해두는 게 나았다. 관찰로 찾은 규칙이다 보니 공식 스펙처럼 믿을 수는 없었고, 안 맞을 때 엉뚱한 데이터를 반환하지 않게 검증과 실패 처리를 같이 뒀다.
