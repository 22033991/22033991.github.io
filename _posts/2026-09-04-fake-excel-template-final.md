---
layout: post
title: '"다운로드는 되는데 업로드가 안 돼요" — 사실은 진짜 엑셀 파일이 아니었다'
date: 2026-09-04 21:00:00 +0900
categories: [개발]
tags: [Apache POI, 엑셀, 파일업로드, Java, 레거시]
excerpt: "템플릿을 받아 그대로 다시 올리면 파싱이 깨졌다. 확장자만 .xls였을 뿐, 실체는 JSP가 뱉은 HTML이었다."
---

전표 업로드에 필요한 템플릿을 다운로드 받고, 내용을 채워 넣은 뒤 엑셀 업로드를 하는 기능을 구현한 적이 있었다. 이런 기능은 주로 대량의 데이터를 넣을 때 사용하기 때문에 템플릿의 정의가 중요하다. 사용자는 "템플릿 다운로드" 버튼으로 양식을 받고, 거기에 데이터를 채운 뒤 다시 업로드하는 흐름이었다. 당시 기본 적으로 사용하던 엑셀 다운로드 메서드를 활용하여, 템플릿 다운로드를 구현했다. 그런데 문제가 발생했다.
템플릿을 다운로드해서 내용을 넣고 바로 재업로드 했을 뿐인데도 파싱이 깨졌다. 프레임워크 기본 기능대로 템플릿 다운로드를 진행했는데, 그 문서를 업로드할 때 해당 템플릿을 읽지 못한다는 게 이상했다.

## 다운로드는 성공, 업로드는 실패

파일이 다운로드는 멀쩡히 됐다. `.xls` 확장자가 붙어 있고, 엑셀 프로그램으로 열어도 표가 보였다. 그런데 그 파일을 그대로 업로드하면 서버에서 파일을 못 읽었다.
원인을 보려고 다운로드 로직을 좀 더 자세히 살펴봤다.

```javascript
// (구) downloadExcelTemplate — 주석 처리된 원본
function downloadExcelTemplate() {
    var f = document.frmFile;
    var defaultNextpage = f.nextpage.value;

    var fileName = "";
    fileName += "ExpenseReport-Template.xls";

    f.nextpage.value = "/excel/excelTemplate.jsp";
    f.action = _webapp + "/ExcelController.excel?down_path=" + f.nextpage.value + "&down_filename=" + fileName;
    jQuery.submitForm(f, "ifrUpload");
}
```

`down_path`가 가리키는 게 `.xls` 바이너리가 아니라 JSP 파일이었다. 즉 서버가 이 JSP를 실행해서 나온 HTML 결과물을, 파일명만 `ExpenseReport-Template.xls`로 붙여서 다운로드시키고 있었다.
사용자 입장에서는 확장자가 `.xls`니까 엑셀 파일이라고 생각하지만, 실제 바이트 내용은 HTML 마크업이었다. 엑셀 프로그램이 그걸 열어서 표처럼 보여줄 수 있었던 건 MS Office가 `.xls` 확장자의 파일 내용을 관대하게 해석해서 HTML 테이블도 어느 정도 렌더링해주기 때문이지, 실제로 OOXML이나 BIFF 포맷의 유효한 엑셀 파일이라서가 아니었다. 실제 엑셀로 동일한 템플릿을 만들어 업로드해보니 그건 또 정상적으로 동작하는 걸 보고 원인을 확정하게 되었다.

## 진짜 바이너리가 아니기 때문에 파싱이 되지 않았다.

업로드 쪽 파싱 코드를 보면, 서버는 업로드된 파일을 실제 엑셀 워크북 포맷으로 읽으려고 시도한다.

```java
// 엑셀 업로드 — 라이브러리를 jxl에서 POI로 교체
//jxl > poi 방식으로 변경
//Workbook workbook = Workbook.getWorkbook(new File(fileVO.getAbsolutePath()));
//Sheet sheet = workbook.getSheet(0);
Workbook workbook = WorkbookFactory.create(new File(fileVO.getAbsolutePath()));
Sheet sheet = workbook.getSheetAt(0);
```

`WorkbookFactory.create()`는 파일 시그니처를 보고 실제 엑셀 바이너리 구조를 파싱하려고 시도한다. 그런데 다운로드된 템플릿의 실체는 HTML이었으니, 이 파서 입장에서는 "엑셀 파일이 아닌 것"을 받은 셈이다. 로그를 보니 `InvalidFormatException`이 나고 있었다.

정리하자면 다운로드는 "HTML을 확장자만 바꿔서 보여주면 된다"는 생각으로, 업로드는 "받은 파일은 당연히 진짜 엑셀 바이너리다"는 생각으로 양쪽의 전제가 어긋나 있었던 것이다.

## 진짜 엑셀 바이너리로 만들기

고치는 방법은 두 가지가 있었다. 업로드 파서가 HTML 테이블도 받아주게 만들거나, 다운로드되는 파일을 진짜 엑셀로 만들거나.

파서 구현 당시에는 고객이 제공한 실무용 엑셀 파일로 업로드를 검증해둔 상태였다. 그래서 업로드 파서를 HTML까지 받아주는 방향으로 바꾸기보다는, 템플릿 다운로드 쪽을 실제 엑셀 파일에 맞추는 게 맞다고 봤다. 그래서 애초에 규격에 맞는 파일이 나가도록 다운로드를 고치기로 했다. Apache POI로 워크북을 직접 생성하도록 바꿨다.

```java
public void downloadExcelTemplate(FormData formData, HttpServletResponse response) throws BusinessException {
    try (Workbook wb = new XSSFWorkbook()) {
        Sheet sheet = wb.createSheet("template-sheet");
        
        Row headerRow = sheet.createRow(0);
        int colNum = 0;
        List<CodeVO> headerCodeList = CodeService.getCdList(cdName);
        Row dataRow = sheet.createRow(1);

        for (CodeVO cd : headerCodeList) {
            Cell headerCell = headerRow.createCell(colNum);
            headerCell.setCellValue(cd.getCdName());

            Cell dataCell = dataRow.createCell(colNum);
            dataCell.setCellValue(cd.getDescription());
            colNum++;
        }
        
        response.setContentType("application/vnd.ms-excel");
        //이게 정석
        //response.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        
        response.setHeader("Content-Disposition", String.format("attachment;filename=%s.xlsx", fileName));
        wb.write(response.getOutputStream());
    } catch (Exception e) {
        throw new BusinessException(e);
    }
}
```

짜면서 신경 쓴 부분은 두 가지다.

먼저 실제 바이너리 스트리밍이다. `XSSFWorkbook`으로 실제 OOXML 구조의 워크북을 메모리에서 만들고, `wb.write()`로 진짜 바이너리를 내보냈다. 확장자도 `.xlsx`로 정직하게 맞췄다. 이제 다운로드된 파일과 업로드 파서가 기대하는 포맷이 일치한다.

두 번째는 `Content-Type`이었다. 원칙적으로 `.xlsx`라면 `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`가 맞다. 다만 당시 환경에서는 자바 버전과 POI 관련 jar 구성이 애매하게 맞물려 있어서, 정석적인 `.xlsx` 응답 구성이 안정적으로 동작하지 않았다. 결국 실제 구현에서는 호환성을 위해 기존에 쓰던 `application/vnd.ms-excel`을 유지했다.

엄밀히 말하면 MIME 타입만으로 파일 포맷이 결정되는 것은 아니다. 중요한 건 실제로 내려보내는 바이트가 HTML인지, POI가 만든 엑셀 워크북인지였다. 


## 업로드 라이브러리와 셀 타입 처리

업로드 쪽 라이브러리도 함께 정리했다. 원래 쓰던 jxl(Java Excel API)은 오래된 라이브러리로 `.xls`(예전 BIFF 포맷) 위주라 지원 범위가 좁았고, POI로 통일하면서 셀 값을 읽는 로직도 같이 바꿨다. 자바 11 환경에 톰캣 버전 제약이 겹쳐 있어서 상위 버전으로 올리긴 어려워 POI 3.x 버전을 썼다.

```java
// POI 3.x 기준
private static final DataFormatter FORMATTER = new DataFormatter();

private String getCellValue(Cell cell) {
    if (cell == null) {
        return "";
    }

    switch (cell.getCellType()) {
        case Cell.CELL_TYPE_FORMULA:
            return cell.getCellFormula();
        case Cell.CELL_TYPE_NUMERIC:
            if (DateUtil.isCellDateFormatted(cell)) {
                return new SimpleDateFormat("yyyy-MM-dd").format(cell.getDateCellValue());
            }
            return FORMATTER.formatCellValue(cell);
        case Cell.CELL_TYPE_STRING:
            return cell.getStringCellValue();
        case Cell.CELL_TYPE_BOOLEAN:
            return String.valueOf(cell.getBooleanCellValue());
        case Cell.CELL_TYPE_BLANK:
        case Cell.CELL_TYPE_ERROR:
        default:
            return "";
    }
}
```

여기서 걸렸던 건 숫자 타입이다. `getNumericCellValue()`는 `double`을 반환하는데, 엑셀은 날짜도 내부적으로 숫자로 저장한다. 그래서 이걸 그냥 `int`로 캐스팅해버리면 소수점이 잘리는 건 물론이고 날짜 컬럼이 `45332` 같은 값으로 바뀐다. 에러가 나는 게 아니라 조용히 값이 망가지는 종류라 더 위험하다.

다만 이 문제가 실제로 터진 적은 없었다. 템플릿에 헤더만 두지 않고 예시 값까지 같이 넣어둔 덕분에, 사용자가 그 형식을 그대로 따라 채워 넣었기 때문이다. 앞에서 템플릿의 정의가 중요하다고 썼는데 그게 여기서 확인됐다. 그래도 템플릿을 벗어난 입력이 언제 들어올지는 모르는 일이라, `DateUtil.isCellDateFormatted()`로 날짜를 먼저 가려내고 나머지 숫자는 `DataFormatter`에 맡겨 엑셀 화면에 보이는 그대로 읽도록 했다.

## 남은 것들

이런 "가짜 엑셀" 패턴은 레거시 시스템에서 종종 보인다. 초기에는 "엑셀처럼 보이기만 하면 된다"는 요구로 시작해서, HTML 테이블을 `.xls` 확장자로 다운로드시키는 간단한 방법을 택하는 경우가 많다. 브라우저와 엑셀 프로그램 둘 다 이 방식을 관대하게 처리해주기 때문에 한동안은 문제없이 굴러간다.

문제는 그 파일을 다시 업로드해서 파싱해야 하는 기능이 나중에 붙을 때다. 아마 다운로드 기능을 만든 사람과 업로드 기능을 만든 사람이 다른 것도 한몫을 했을 것이다. 그리고 사용자는 주로 본인이 쓰던 실제 엑셀 파일로 업로드를 해왔기 때문에, 정작 기본 제공 템플릿의 오류를 발견하는 것이 늦어졌을 것이다.

이번에 다시 느낀 건, 다운로드와 업로드가 짝을 이루는 기능에서는 "엑셀에서 열린다"와 "엑셀 파일이다"를 같은 말로 보면 안 된다는 점이었다.
