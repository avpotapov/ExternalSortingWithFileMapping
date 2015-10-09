unit ExtSortFile;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Generics.Collections,
  Winapi.Windows;

const
  // Размер буфера для серий 256Kb,
  SERIES_BUFFER_SIZE = $40000;
  // Размер буфера для файлов-серий 64Kb при слиянии,
  MERGE_READER_BUFFER_SIZE = SERIES_BUFFER_SIZE shr 2;
  // Размер буфера для файла, как результат слияния 2 серий 128Kb,
  MERGE_WRITER_BUFFER_SIZE = SERIES_BUFFER_SIZE shr 1;

type
  EFile = class(Exception);

  IFile = interface
    ['{173D47FB-6C38-4718-B604-E5D1097FC45E}']
    procedure Open(const AFileName: string);
    procedure Close;
    function GetFileSize: Int64;
    property FileSize: Int64 read GetFileSize;
  end;

  IFileReader = interface(IFile)
    ['{B051E9F5-84E9-4477-A551-AD803BF231E6}']
    function ToRead(const AList: TList<AnsiString>): Integer;
  end;

  IFileWriter = interface(IFile)
    ['{C34BA975-78AF-4322-912A-9A5A0ED3FE84}']
    procedure ToWrite(const AList: TList<AnsiString>);
  end;
{$REGION 'TAbstractFile'}

  TAbstractFile = class abstract(TInterfacedObject, IFile)
  protected
    function GetFileSize: Int64; virtual; abstract;
  public
    procedure Open(const AFileName: string); virtual; abstract;
    procedure Close; virtual; abstract;
    property FileSize: Int64 read GetFileSize;
  end;

{$ENDREGION}
{$REGION 'TAbstractFileMapping'}

  TAbstractFileMapping = class(TAbstractFile)
  protected
    // Смещение начальное границы отображения файла
    FOffset: Int64;
    // Размер отображения данных
    FBufferSize: DWord;
    // Handle файла отображения
    FFileMapping: THandle;
    // Указатель на область отображения
    FMapView: Pointer;
    // Размер файла
    FFileSize: Int64;

    function CreateFile(const AFileName: string): THandle; virtual; abstract;
    procedure CreateFileMapping(const AhFile: THandle); virtual; abstract;
    procedure MapViewOfFile; virtual; abstract;
    procedure CalculateBoundaryMapView;
    function GetFileSize: Int64; override;
    procedure ReMapViewFile;
  public
    constructor Create(const ABufferSize: DWord); reintroduce; virtual;
    procedure Open(const AFileName: string); override;
    procedure Close; override;
  end;
{$ENDREGION}
{$REGION 'TFileMappingReader'}

  TFileMappingReader = class(TAbstractFileMapping)
  protected
    function CreateFile(const AFileName: string): THandle; override;
    procedure CreateFileMapping(const AhFile: THandle); override;
    procedure MapViewOfFile; override;
  end;

{$ENDREGION}
{$REGION 'TFileMappingWriter'}

  TFileMappingWriter = class(TAbstractFileMapping)
  protected
    FEstimatedFileSize: Int64;
    function CreateFile(const AFileName: string): THandle; override;
    procedure CreateFileMapping(const AhFile: THandle); override;
    procedure MapViewOfFile; override;
  public
    constructor Create(const AEstimatedFileSize: Int64; const ABufferSize: DWord); reintroduce;
  end;

{$ENDREGION}
{$REGION 'TFileReader'}

  TFileReader = class(TFileMappingReader, IFileReader)
    FRemainString: AnsiString;
    FCriticalSection: TRtlCriticalSection;
    function RetrieveBoundaryString(const AStartPos: Int64; var AEndPos: Int64): Boolean;
  public
    function ToRead(const AList: TList<AnsiString>): Integer;
    constructor Create(const ABufferSize: DWord); override;
    destructor Destroy; override;
  end;

{$ENDREGION}
{$REGION 'TFileWriter'}

  TFileWriter = class(TFileMappingWriter, IFileWriter)
    FRemainMemory: Int64;
    procedure ToWrite(AString: AnsiString); overload;
  public
    procedure ToWrite(const AList: TList<AnsiString>); overload;
    class function MakeRandomFileName: string;
  end;

{$ENDREGION}

implementation

{$REGION 'TAbstractFileMapping'}

constructor TAbstractFileMapping.Create(const ABufferSize: DWord);
begin
  FBufferSize := ABufferSize;
end;

function TAbstractFileMapping.GetFileSize: Int64;
begin
  Result := FFileSize;
end;

procedure TAbstractFileMapping.Open(const AFileName: string);
var
  hFile: THandle;
begin
  // Открыть файл (чтение, запись)
  hFile := CreateFile(AFileName);
  // Записать размер файла
  FFileSize := Winapi.Windows.GetFileSize(hFile, nil);
  // Начальное смещение
  FOffset := 0;
  // Создание отображения в память
  CreateFileMapping(hFile);
  CloseHandle(hFile);
end;

procedure TAbstractFileMapping.ReMapViewFile;
begin
  // Расчитать размер отображения данных файла
  CalculateBoundaryMapView;
  // Закрыть старое представление ...
  if FMapView <> nil then
    UnmapViewOfFile(FMapView);
  // и открыть новое
  MapViewOfFile;
end;

procedure TAbstractFileMapping.Close;
begin
  // Закрыть представление
  if FMapView <> nil then
    UnmapViewOfFile(FMapView);
  // Освободим объект FileMapping
  if FFileMapping <> 0 then
    CloseHandle(FFileMapping);
end;

procedure TAbstractFileMapping.CalculateBoundaryMapView;
var
  // Структура для определения гранулярности памяти
  SystemInfo: TSystemInfo;
  // Минимальный размер резервируемой области памяти
  AllocationGranularity: DWord;
begin
  // Смещение нужно задавать таким образом, чтобы оно попадало на границу
  // минимального пространства памяти, которое можно зарезервировать.
  // Более точно гранулярность памяти можно определить при помощи функции GetSystemInfo.
  GetSystemInfo(SystemInfo);
  // В поле dwAllocationGranularity будет записан минимальный размер резервируемой области памяти.
  AllocationGranularity := SystemInfo.dwAllocationGranularity;
  // Начало отображения файла
  FOffset := (FOffset div AllocationGranularity) * AllocationGranularity;
  // Размер представления проекции
  FBufferSize := (FOffset mod AllocationGranularity) + FBufferSize;
  if (FFileSize < (FOffset + FBufferSize)) then
    FBufferSize := FFileSize - FOffset;
end;
{$ENDREGION}
{$REGION 'TFileMappingReader'}

function TFileMappingReader.CreateFile(const AFileName: string): THandle;
begin
  // Открываем файл для совместного чтения
  Result := Winapi.Windows.CreateFile(PChar(AFileName), // Имя файла
    GENERIC_READ,                                       // Только чтения
    FILE_SHARE_READ,                                    // Совместное чтение
    nil,                                                // Защита по умолчанию
    OPEN_EXISTING,                                      // Только существующий файл
    FILE_ATTRIBUTE_NORMAL,                              // Обычный файл
    0);                                                 // Атрибутов шаблона нет

  if (Result = INVALID_HANDLE_VALUE) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingReader.CreateFileMapping(const AhFile: THandle);
begin
  // Cоздаем объект файла, проецируемого в память
  FFileMapping := Winapi.Windows.CreateFileMapping(AhFile, // дескриптор файла
    nil,                                                   // атрибуты защиты
    PAGE_READONLY,                                         // флаги доступа к файлу
    0,                                                     // старшее двойное слово размера объекта
    0,                                                     // младшее двойное слово размера объекта  (весь файл)
    '');                                                   // имя объекта отображения

  if (FFileMapping = 0) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingReader.MapViewOfFile;
begin
  // Подключаем файл к адресному пространству и получаем начальный адрес данных
  FMapView := Winapi.Windows.MapViewOfFile(FFileMapping, // дескриптор объекта, отображающего файл
    FILE_MAP_READ,                                       // режим доступа
    FOffset shr $20,                                     // старшее двойное слово смещения
    FOffset,                                             // младшее двойное слово смещения
    FBufferSize); // количество отображаемых байт, если 0, то будет считан весь файл.

  if not Assigned(FMapView) then
    raise EFile.Create(SysErrorMessage(GetLastError()));

  if (FFileSize < (FOffset + FBufferSize)) then
    FBufferSize := FFileSize - FOffset;

  // Инкрементируем смещение
  Inc(FOffset, FBufferSize);

end;
{$ENDREGION}
{$REGION 'TFileMappingWriter'}

constructor TFileMappingWriter.Create(const AEstimatedFileSize: Int64; const ABufferSize: DWord);
begin
  inherited Create(ABufferSize);
  FEstimatedFileSize := AEstimatedFileSize;
end;

function TFileMappingWriter.CreateFile(const AFileName: string): THandle;
begin
  // Открываем файл для записи
  Result := Winapi.Windows.CreateFile(PChar(AFileName), // Имя файла
    GENERIC_WRITE or GENERIC_READ,                      // Только  запись
    0,                                                  //
    nil,                                                // Защита по умолчанию
    CREATE_ALWAYS,                                      // Новый файл
    FILE_ATTRIBUTE_NORMAL,                              // Обычный файл
    0);                                                 // Атрибутов шаблона нет

  if (Result = INVALID_HANDLE_VALUE) then
    raise EFile.Create(SysErrorMessage(GetLastError));

  SetFilePointer(Result, FEstimatedFileSize, nil, FILE_BEGIN);
  SetEndOfFile(Result);

end;

procedure TFileMappingWriter.CreateFileMapping(const AhFile: THandle);
begin
  // Cоздаем объект файла, проецируемого в память
  FFileMapping := Winapi.Windows.CreateFileMapping(AhFile, // дескриптор файла
    nil,                                                   // атрибуты защиты
    PAGE_READWRITE,                                        // флаги доступа к файлу
    0,                                                     // старшее двойное слово размера объекта
    0,                                                     // младшее двойное слово размера объекта  (весь файл)
    '');                                                   // имя объекта отображения

  if (FFileMapping = 0) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingWriter.MapViewOfFile;
begin
  // Подключаем файл к адресному пространству и получаем начальный адрес данных
  FMapView := Winapi.Windows.MapViewOfFile(FFileMapping, // дескриптор объекта, отображающего файл
    FILE_MAP_WRITE,                                      // режим доступа
    FOffset shr $20,                                     // старшее двойное слово смещения
    FOffset,                                             // младшее двойное слово смещения
    FBufferSize); // количество отображаемых байт, если 0, то будет считан весь файл.

  if not Assigned(FMapView) then
    raise EFile.Create(SysErrorMessage(GetLastError()));

  // Инкрементируем смещение
  Inc(FOffset, FBufferSize);
end;
{$ENDREGION}
{$REGION 'TFileReader'}

constructor TFileReader.Create(const ABufferSize: DWord);
begin
  inherited Create(ABufferSize);
  InitializeCriticalSection(FCriticalSection);
end;

destructor TFileReader.Destroy;
begin
  DeleteCriticalSection(FCriticalSection);
  inherited;
end;

function TFileReader.RetrieveBoundaryString(const AStartPos: Int64; var AEndPos: Int64): Boolean;
var
  // Начальный символ
  StartPtr: PAnsiChar;
begin
  Result := False;
  // Перемещаем указатель на нужный символ
  StartPtr := PAnsiChar(FMapView) + AStartPos;
  AEndPos  := AStartPos;
  // Ищем символы #13#10 конца строки
  while (AEndPos < (FBufferSize - 1)) do
  begin
    // Конец строки
    if (PAnsiChar(StartPtr)^ = #13) and (PAnsiChar(StartPtr + 1)^ = #10) then
      Exit(True);
    // Следующий символ
    Inc(StartPtr);
    // Следующая позиция символа
    Inc(AEndPos);
  end;
end;

function TFileReader.ToRead(const AList: TList<AnsiString>): Integer;
var
  // Начальный символ
  SrcP: PAnsiChar;
  // Первый байт данных
  CurPos: Int64;
  // Последний байт данных
  EndStrPos: Int64;
  // Длина строки
  LengthStr: Word;
  // Строка
  S: AnsiString;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := 0;
    // Конец файла
    if FOffset = FFileSize then
      Exit;

    // Отобразить часть файла в память
    ReMapViewFile;

    CurPos := 0;
    // Получить границу строку
    // Конец строки содержится в EndPos без учета CRLF
    while RetrieveBoundaryString(CurPos, EndStrPos) do
    begin
      // Размер длина строки
      LengthStr := EndStrPos - CurPos;

      // Сохраняем в строку
      SetLength(S, LengthStr);
      SrcP := PAnsiChar(FMapView) + CurPos;
      System.Move(SrcP^, S[1], LengthStr);
      Inc(Result, LengthStr);

      // Если был отстаток строки, то добавляем его вначало
      if FRemainString <> '' then
      begin
        S             := FRemainString + S;
        Inc(Result, Length(FRemainString));
        FRemainString := '';
      end;

      // Добавляем строку в контейнер
      AList.Add(S);
      // Изменяем смещение
      CurPos := EndStrPos + 2;
      Inc(Result, 2);
    end;

    // Записать хвост в начало дампа
    // Может быть начало незаконченной строки
    // сохраняем в хвост
    // Размер длина строки
    LengthStr := EndStrPos - CurPos;
    // Сохраняем в строку
    if LengthStr > 0 then
    begin
      SetLength(FRemainString, LengthStr + 1);
      SrcP := PAnsiChar(FMapView) + CurPos;
      System.Move(SrcP^, FRemainString[1], LengthStr + 1);
    end;

  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;
{$ENDREGION}
{$REGION 'TFileWriter'}

class function TFileWriter.MakeRandomFileName: string;
var
  Guid     : TGuid;
  StartChar: Integer;
  EndChar  : Integer;
  Count    : Integer;
begin
  CreateGuid(Guid);
  Result := GuidToString(Guid);

  StartChar := Pos('{', Result) + 1;
  EndChar   := Pos('}', Result) - 1;
  Count     := EndChar - StartChar + 1;

  Result := Copy(Result, StartChar, Count);
  Result := Result + '.temp';
end;

procedure TFileWriter.ToWrite(const AList: TList<AnsiString>);
const
  CRLF: AnsiString = #13#10;
var
  S: AnsiString;
begin
  for S in AList do
    // Добавим к текущей строке конец строки и запишем в память
    ToWrite(S + CRLF);
end;

procedure TFileWriter.ToWrite(AString: AnsiString);
var
  DscP        : PAnsiChar;
  Offset      : Int64;
  WrittenBytes: Integer;
begin
  // Если нет доступной памяти, необходимо выделить
  if FRemainMemory = 0 then
  begin
    ReMapViewFile;
    FRemainMemory := FBufferSize;
  end;

  // Текущее смещение от начала представления
  Offset := FBufferSize - FRemainMemory;
  // Найдем минимальный размер для записи в файл
  // из свободной части файла отображения и длины строки
  WrittenBytes := Min(Length(AString), FRemainMemory);
  // Ставим указатель на следующий символ
  // Смещение относительно первого символа текущего отображения
  DscP := PAnsiChar(FMapView) + Offset;
  // Пишем в файл
  System.Move(AString[1], DscP^, WrittenBytes);
  // Уменьшаем остаток памяти на размер записанных байт
  Dec(FRemainMemory, WrittenBytes);

  // Остаток строки
  if Length(AString) > WrittenBytes then
    // записываем вновь, создав новое представление
    ToWrite(Copy(AString, WrittenBytes + 1, Length(AString) - WrittenBytes));
end;
{$ENDREGION}

end.
