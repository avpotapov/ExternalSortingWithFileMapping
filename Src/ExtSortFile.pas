unit ExtSortFile;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Generics.Collections,
  Winapi.Windows;

const
  // ������ ������ ��� ����� 256Kb,
  SERIES_BUFFER_SIZE = $40000;
  // ������ ������ ��� ������-����� 64Kb ��� �������,
  MERGE_READER_BUFFER_SIZE = SERIES_BUFFER_SIZE shr 2;
  // ������ ������ ��� �����, ��� ��������� ������� 2 ����� 128Kb,
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
    // �������� ��������� ������� ����������� �����
    FOffset: Int64;
    // ������ ����������� ������
    FBufferSize: DWord;
    // Handle ����� �����������
    FFileMapping: THandle;
    // ��������� �� ������� �����������
    FMapView: Pointer;
    // ������ �����
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
  // ������� ���� (������, ������)
  hFile := CreateFile(AFileName);
  // �������� ������ �����
  FFileSize := Winapi.Windows.GetFileSize(hFile, nil);
  // ��������� ��������
  FOffset := 0;
  // �������� ����������� � ������
  CreateFileMapping(hFile);
  CloseHandle(hFile);
end;

procedure TAbstractFileMapping.ReMapViewFile;
begin
  // ��������� ������ ����������� ������ �����
  CalculateBoundaryMapView;
  // ������� ������ ������������� ...
  if FMapView <> nil then
    UnmapViewOfFile(FMapView);
  // � ������� �����
  MapViewOfFile;
end;

procedure TAbstractFileMapping.Close;
begin
  // ������� �������������
  if FMapView <> nil then
    UnmapViewOfFile(FMapView);
  // ��������� ������ FileMapping
  if FFileMapping <> 0 then
    CloseHandle(FFileMapping);
end;

procedure TAbstractFileMapping.CalculateBoundaryMapView;
var
  // ��������� ��� ����������� ������������� ������
  SystemInfo: TSystemInfo;
  // ����������� ������ ������������� ������� ������
  AllocationGranularity: DWord;
begin
  // �������� ����� �������� ����� �������, ����� ��� �������� �� �������
  // ������������ ������������ ������, ������� ����� ���������������.
  // ����� ����� ������������� ������ ����� ���������� ��� ������ ������� GetSystemInfo.
  GetSystemInfo(SystemInfo);
  // � ���� dwAllocationGranularity ����� ������� ����������� ������ ������������� ������� ������.
  AllocationGranularity := SystemInfo.dwAllocationGranularity;
  // ������ ����������� �����
  FOffset := (FOffset div AllocationGranularity) * AllocationGranularity;
  // ������ ������������� ��������
  FBufferSize := (FOffset mod AllocationGranularity) + FBufferSize;
  if (FFileSize < (FOffset + FBufferSize)) then
    FBufferSize := FFileSize - FOffset;
end;
{$ENDREGION}
{$REGION 'TFileMappingReader'}

function TFileMappingReader.CreateFile(const AFileName: string): THandle;
begin
  // ��������� ���� ��� ����������� ������
  Result := Winapi.Windows.CreateFile(PChar(AFileName), // ��� �����
    GENERIC_READ,                                       // ������ ������
    FILE_SHARE_READ,                                    // ���������� ������
    nil,                                                // ������ �� ���������
    OPEN_EXISTING,                                      // ������ ������������ ����
    FILE_ATTRIBUTE_NORMAL,                              // ������� ����
    0);                                                 // ��������� ������� ���

  if (Result = INVALID_HANDLE_VALUE) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingReader.CreateFileMapping(const AhFile: THandle);
begin
  // C������ ������ �����, ������������� � ������
  FFileMapping := Winapi.Windows.CreateFileMapping(AhFile, // ���������� �����
    nil,                                                   // �������� ������
    PAGE_READONLY,                                         // ����� ������� � �����
    0,                                                     // ������� ������� ����� ������� �������
    0,                                                     // ������� ������� ����� ������� �������  (���� ����)
    '');                                                   // ��� ������� �����������

  if (FFileMapping = 0) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingReader.MapViewOfFile;
begin
  // ���������� ���� � ��������� ������������ � �������� ��������� ����� ������
  FMapView := Winapi.Windows.MapViewOfFile(FFileMapping, // ���������� �������, ������������� ����
    FILE_MAP_READ,                                       // ����� �������
    FOffset shr $20,                                     // ������� ������� ����� ��������
    FOffset,                                             // ������� ������� ����� ��������
    FBufferSize); // ���������� ������������ ����, ���� 0, �� ����� ������ ���� ����.

  if not Assigned(FMapView) then
    raise EFile.Create(SysErrorMessage(GetLastError()));

  if (FFileSize < (FOffset + FBufferSize)) then
    FBufferSize := FFileSize - FOffset;

  // �������������� ��������
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
  // ��������� ���� ��� ������
  Result := Winapi.Windows.CreateFile(PChar(AFileName), // ��� �����
    GENERIC_WRITE or GENERIC_READ,                      // ������  ������
    0,                                                  //
    nil,                                                // ������ �� ���������
    CREATE_ALWAYS,                                      // ����� ����
    FILE_ATTRIBUTE_NORMAL,                              // ������� ����
    0);                                                 // ��������� ������� ���

  if (Result = INVALID_HANDLE_VALUE) then
    raise EFile.Create(SysErrorMessage(GetLastError));

  SetFilePointer(Result, FEstimatedFileSize, nil, FILE_BEGIN);
  SetEndOfFile(Result);

end;

procedure TFileMappingWriter.CreateFileMapping(const AhFile: THandle);
begin
  // C������ ������ �����, ������������� � ������
  FFileMapping := Winapi.Windows.CreateFileMapping(AhFile, // ���������� �����
    nil,                                                   // �������� ������
    PAGE_READWRITE,                                        // ����� ������� � �����
    0,                                                     // ������� ������� ����� ������� �������
    0,                                                     // ������� ������� ����� ������� �������  (���� ����)
    '');                                                   // ��� ������� �����������

  if (FFileMapping = 0) then
    raise EFile.Create(SysErrorMessage(GetLastError));
end;

procedure TFileMappingWriter.MapViewOfFile;
begin
  // ���������� ���� � ��������� ������������ � �������� ��������� ����� ������
  FMapView := Winapi.Windows.MapViewOfFile(FFileMapping, // ���������� �������, ������������� ����
    FILE_MAP_WRITE,                                      // ����� �������
    FOffset shr $20,                                     // ������� ������� ����� ��������
    FOffset,                                             // ������� ������� ����� ��������
    FBufferSize); // ���������� ������������ ����, ���� 0, �� ����� ������ ���� ����.

  if not Assigned(FMapView) then
    raise EFile.Create(SysErrorMessage(GetLastError()));

  // �������������� ��������
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
  // ��������� ������
  StartPtr: PAnsiChar;
begin
  Result := False;
  // ���������� ��������� �� ������ ������
  StartPtr := PAnsiChar(FMapView) + AStartPos;
  AEndPos  := AStartPos;
  // ���� ������� #13#10 ����� ������
  while (AEndPos < (FBufferSize - 1)) do
  begin
    // ����� ������
    if (PAnsiChar(StartPtr)^ = #13) and (PAnsiChar(StartPtr + 1)^ = #10) then
      Exit(True);
    // ��������� ������
    Inc(StartPtr);
    // ��������� ������� �������
    Inc(AEndPos);
  end;
end;

function TFileReader.ToRead(const AList: TList<AnsiString>): Integer;
var
  // ��������� ������
  SrcP: PAnsiChar;
  // ������ ���� ������
  CurPos: Int64;
  // ��������� ���� ������
  EndStrPos: Int64;
  // ����� ������
  LengthStr: Word;
  // ������
  S: AnsiString;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := 0;
    // ����� �����
    if FOffset = FFileSize then
      Exit;

    // ���������� ����� ����� � ������
    ReMapViewFile;

    CurPos := 0;
    // �������� ������� ������
    // ����� ������ ���������� � EndPos ��� ����� CRLF
    while RetrieveBoundaryString(CurPos, EndStrPos) do
    begin
      // ������ ����� ������
      LengthStr := EndStrPos - CurPos;

      // ��������� � ������
      SetLength(S, LengthStr);
      SrcP := PAnsiChar(FMapView) + CurPos;
      System.Move(SrcP^, S[1], LengthStr);
      Inc(Result, LengthStr);

      // ���� ��� �������� ������, �� ��������� ��� �������
      if FRemainString <> '' then
      begin
        S             := FRemainString + S;
        Inc(Result, Length(FRemainString));
        FRemainString := '';
      end;

      // ��������� ������ � ���������
      AList.Add(S);
      // �������� ��������
      CurPos := EndStrPos + 2;
      Inc(Result, 2);
    end;

    // �������� ����� � ������ �����
    // ����� ���� ������ ������������� ������
    // ��������� � �����
    // ������ ����� ������
    LengthStr := EndStrPos - CurPos;
    // ��������� � ������
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
    // ������� � ������� ������ ����� ������ � ������� � ������
    ToWrite(S + CRLF);
end;

procedure TFileWriter.ToWrite(AString: AnsiString);
var
  DscP        : PAnsiChar;
  Offset      : Int64;
  WrittenBytes: Integer;
begin
  // ���� ��� ��������� ������, ���������� ��������
  if FRemainMemory = 0 then
  begin
    ReMapViewFile;
    FRemainMemory := FBufferSize;
  end;

  // ������� �������� �� ������ �������������
  Offset := FBufferSize - FRemainMemory;
  // ������ ����������� ������ ��� ������ � ����
  // �� ��������� ����� ����� ����������� � ����� ������
  WrittenBytes := Min(Length(AString), FRemainMemory);
  // ������ ��������� �� ��������� ������
  // �������� ������������ ������� ������� �������� �����������
  DscP := PAnsiChar(FMapView) + Offset;
  // ����� � ����
  System.Move(AString[1], DscP^, WrittenBytes);
  // ��������� ������� ������ �� ������ ���������� ����
  Dec(FRemainMemory, WrittenBytes);

  // ������� ������
  if Length(AString) > WrittenBytes then
    // ���������� �����, ������ ����� �������������
    ToWrite(Copy(AString, WrittenBytes + 1, Length(AString) - WrittenBytes));
end;
{$ENDREGION}

end.
