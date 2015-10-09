unit ExtSortThread;

interface

{$REGION 'Описание модуля'}
(*
  *  Модуль объектов сортировки
  *
  *  Алгорит сортировки состоит из 2 фаз
  *
  *  - СОЗДАНИЕ СЕРИЙ
  *  Запущенные SeriesCreator порционно считывают переданные им части файла в буфер обмена,
  *  размер которого лимитирован.
  *  Затем в буфере выполняется быстрая сортировка строк методом QuickSort. Учитывается длина
  *  сортируемой строки.
  *  В итоге образуется серия (отсортированный отрезок), который сохраняется в файл.
  *  Имя файла помещается в потокобезопасную очередь MergeController.
  *  Далее цикл повторяется, пока не будет обработан таким образом последний участок файла
  *
  *  - СЛИЯНИЕ
  *  Как только в буфере MergeController появляются 2 и более отрезка, запускается создание
  *  объекта слияния, которому передаются имена отрезков
  *  Процесс повторяется пока очередь не опустеет
  *  В объекте объединяются два файла в один, используя функцию слияния.
  *  Если размер файла соответствует размеру неотсортированного файла, то цель достигнута.
  *  Сортировка прекращается.
  *  В противном случае файл передается контроллеру слияния.
  *  Количество одновременно работающих потоков не превышает 4. За это отвечает семафор в
  *  контроллере слияния
*)
{$ENDREGION}

uses
  Winapi.Windows,
  Winapi.Messages,

  System.Classes,
  System.AnsiStrings,
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.SysUtils,

  Vcl.Forms,

  ExtSortFile;

const
  MAX_SIZE_COMPARE_STRING = 50;
  NUMBER_PROCESSOR        = 4;

  WM_SORT_HAS_FINISHED = WM_USER + 1;

type
  TSortClass = class of TAbstractSort;

  ISort = interface
    ['{584FBB13-9C6E-407A-A9BD-1643D5248946}']
    procedure Start;
    procedure Stop;
    procedure SetSrcFileReader(Value: IFileReader);
    /// <summary>
    /// Сортируемый файл
    /// </summary>
    property SrcFileReader: IFileReader write SetSrcFileReader;
  end;

  /// <summary>
  /// Управляет процессом слияния файлов:
  /// накапливает имена файлов - отрезков в списке,
  /// запускает слияние двух файлов
  /// </summary>
  IMergeController = interface(ISort)
    ['{B9235DAE-87E5-4F03-9D44-109B1C86C468}']
    function Add(const AFilename: string): Boolean;
    procedure SetMergerClass(const Value: TSortClass);
    function GetDscFileName: string;
    procedure SetDscFileName(const Value: string);

    /// <summary>
    /// Класс объекта слияния
    /// </summary>
    property MergerClass: TSortClass write SetMergerClass;
    property DscFileName: string read GetDscFileName write SetDscFileName;
  end;

  IPhase = interface(ISort)
    ['{ED42A5DE-6DB1-419C-B1B7-6D318E5F66F0}']
    procedure SetMergeController(Value: IMergeController);
    /// <summary>
    /// Контроллер слияния
    /// </summary>
    property MergeController: IMergeController write SetMergeController;
  end;

  /// <summary>
  /// Производит слияния файлов:
  /// если размер нового файла слияния меньше размера исходного файла,
  /// передает этот файл контроллеру слияния,
  /// в противном случае цель достугнута.
  /// </summary>
  IMerger = interface(IPhase)
    ['{21D4607E-B847-4023-BB0C-BA8F050FD2CF}']
    procedure SetLeftFileName(const Value: string);
    procedure SetRightFileName(const Value: string);
    procedure SetDscFileName(const Value: string);
    /// <summary>
    /// Первый файл слияния
    /// </summary>
    property LeftFileName: string write SetLeftFileName;
    /// <summary>
    /// Второй файл слияния
    /// </summary>
    property RightFileName: string write SetRightFileName;
    /// <summary>
    /// Имя отсортированного файла
    /// </summary>
    property DscFileName: string write SetDscFileName;
  end;
{$REGION 'TSort'}

  TAbstractSort = class abstract(TInterfacedObject, ISort)
  protected
    class var FStop: Integer;
  protected
    FSrcFileReader: IFileReader;
    FThread       : TThread;
  private
    procedure SetSrcFileReader(Value: IFileReader);
  public
    constructor Create; reintroduce; virtual;
    destructor Destroy; override;
  public
    class procedure Initialize;
    function HasStopped: Boolean;
    procedure Stop; virtual;
    procedure Start; virtual; abstract;
    property SrcFileReader: IFileReader write SetSrcFileReader;
  end;
{$ENDREGION}
{$REGION 'TPhase'}

  TMergeController = class;

  TPhase = class(TAbstractSort)
  protected
    FMergeController: TMergeController;
  private
    procedure SetMergeController(Value: IMergeController);
  public
    property MergeController: IMergeController write SetMergeController;
  end;
{$ENDREGION}
{$REGION 'TSeries'}

  /// <summary>
  /// Из считанных частей файла в буфер (размер буфера ограничен)
  /// создает отрезок,
  /// сохраняет его в файл,
  /// и передает контроллеру слияния
  /// </summary>
  TSeriesCreator = class(TPhase, IPhase)
    FEof: Boolean;
    FStringList: TList<AnsiString>;
    FSeriesFileSize: Integer;
    FMerge: TMergeController;
    function PopulateStringList: Boolean;
    procedure SortStringList;
    procedure SaveStringList;
    procedure NotifyMergeManager(const ASeriesFileName: string);
  public
    constructor Create; override;
    destructor Destroy; override;
  public
    procedure Start; override;
  end;

{$ENDREGION}
{$REGION 'TMergeController'}

  TMergeController = class(TAbstractSort, IMergeController)
    FDscFileName: string;
    FMergerClass: TSortClass;
    FCounter: Integer;
    FMerges: TList<ISort>;
    FQueue: TQueue<string>;
    FMutex: THandle;
    FSemaphore: THandle;
    // FMutex + FSemaphore
    FWaitHandles: array [0 .. 1] of THandle;
    procedure SetMergerClass(const Value: TSortClass);
    function GetDscFileName: string;
    procedure SetDscFileName(const Value: string);
  public
    constructor Create; override;
    destructor Destroy; override;
  public
    procedure HasDone;
    procedure Start; override;
    function Add(const AFilename: string): Boolean;
    property MergerClass: TSortClass write SetMergerClass;
    property DscFileName: string read GetDscFileName write SetDscFileName;
  end;
{$ENDREGION}
{$REGION 'TMerger'}

type
  TQueueList<T> = class(TList<T>)
  public
    function Pop(var AItem: T): Boolean;
  end;

  TMerger = class(TPhase, IMerger)
    FLeftFileName, FRightFileName, FDscFileName: string;
    FRightStringList, FLeftStringList: TQueueList<AnsiString>;
    FMergeStringList: TList<AnsiString>;
    procedure SetLeftFileName(const Value: string);
    procedure SetRightFileName(const Value: string);
    procedure SetDscFileName(const Value: string);
    procedure MergeFiles;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Start; override;
    property LeftFileName: string write SetLeftFileName;
    property RightFileName: string write SetRightFileName;
    property DscFileName: string write SetDscFileName;
  end;

{$ENDREGION}

implementation

uses
  ExtSortFactory;

function CompareShortString(const Left, Right: AnsiString): Integer;
var
  L, R: Word;
begin
  L      := Length(Left);
  R      := Length(Right);
  Result := System.AnsiStrings.AnsiStrLComp(@Left[1], @Right[1], Min(MAX_SIZE_COMPARE_STRING, Min(L, R)));
  if (Result = 0) and (L < R) then
    Result := -1;
  if (Result = 0) and (L > R) then
    Result := 1;
end;

{$REGION 'TSort'}

class procedure TAbstractSort.Initialize;
begin
  FStop := 0;
end;

constructor TAbstractSort.Create;
begin
  inherited;
end;

destructor TAbstractSort.Destroy;
begin
  Stop;
  FreeAndNil(FThread);
  inherited;
end;

function TAbstractSort.HasStopped: Boolean;
begin
  Result := InterlockedCompareExchange(FStop, 1, 1) = 1;
end;

procedure TAbstractSort.SetSrcFileReader(Value: IFileReader);
begin
  FSrcFileReader := Value;
end;

procedure TAbstractSort.Stop;
begin
  InterlockedExchange(FStop, 1);
end;

{$ENDREGION}
{$REGION 'TPhase'}

procedure TPhase.SetMergeController(Value: IMergeController);
begin
  FMergeController := Value as TMergeController;
end;
{$ENDREGION}
{$REGION 'TSeries'}

constructor TSeriesCreator.Create;
begin
  inherited;
  FStringList := TList<AnsiString>.Create;
  FEof        := False;
end;

destructor TSeriesCreator.Destroy;
begin
  inherited;
  FreeAndNil(FStringList);
end;

procedure TSeriesCreator.NotifyMergeManager(const ASeriesFileName: string);
begin
  // Отправить файл для завершающего слияния
  while not HasStopped do
    if FMergeController.Add(ASeriesFileName) then
      Break;
end;

function TSeriesCreator.PopulateStringList: Boolean;
begin
  FStringList.Clear;
  FSeriesFileSize := FSrcFileReader.ToRead(FStringList);
  Result          := FSeriesFileSize <> 0;
end;

procedure TSeriesCreator.SortStringList;
begin
  FStringList.Sort(TComparer<AnsiString>.Construct(CompareShortString));
end;

procedure TSeriesCreator.SaveStringList;
var
  S             : AnsiString;
  FileWriter    : IFileWriter;
  SeriesFileName: string;
begin
  SeriesFileName := TFileWriter.MakeRandomFileName;
  FileWriter     := TFileWriter.Create(FSeriesFileSize, SERIES_BUFFER_SIZE) as IFileWriter;
  FileWriter.Open(SeriesFileName);
  try
    // Сохранить серию в файл
    FileWriter.ToWrite(FStringList);
    // Отправить имя файла менеджеру слияний
    NotifyMergeManager(SeriesFileName);
  finally
    FileWriter.Close;
  end;
end;

procedure TSeriesCreator.Start;
begin
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      while not HasStopped do
      begin
        try
          if PopulateStringList then
          begin
            SortStringList;
            SaveStringList;
          end;
        finally
          FMergeController.HasDone;
        end;
      end;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

{$ENDREGION}
{$REGION 'TMergeController'}

constructor TMergeController.Create;
begin
  inherited;
  FCounter        := 0;
  FMutex          := CreateMutex(nil, False, '');
  FSemaphore      := CreateSemaphore(nil, 0, NUMBER_PROCESSOR, '');
  FWaitHandles[0] := FMutex;
  FWaitHandles[1] := FSemaphore;
  FQueue          := TQueue<string>.Create;
  FMerges         := TList<ISort>.Create;
end;

destructor TMergeController.Destroy;
begin
  inherited;
  CloseHandle(FMutex);
  CloseHandle(FSemaphore);
  FreeAndNil(FQueue);
  FreeAndNil(FMerges);
end;

function TMergeController.GetDscFileName: string;
begin
  Result := FDscFileName;
end;

procedure TMergeController.HasDone;
var
  PrevCount: LongInt;
begin
  ReleaseSemaphore(FSemaphore, 1, @PrevCount);
end;

procedure TMergeController.SetDscFileName(const Value: string);
begin
  if FDscFileName <> Value then
     FDscFileName := Value;
end;

procedure TMergeController.SetMergerClass(const Value: TSortClass);
begin
  FMergerClass := Value;
end;

function TMergeController.Add(const AFilename: string): Boolean;
begin
  if WaitForSingleObject(FMutex, 1000) <> WAIT_OBJECT_0 then
    Exit(False);
  try
    FQueue.Enqueue(AFilename);
    Result := True;
  finally
    ReleaseMutex(FMutex);
  end;
end;

procedure TMergeController.Start;
var
  Merge: ISort;
begin
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      while not HasStopped do
        case WaitForMultipleObjects(2, @FWaitHandles, True, 1000) of
          WAIT_OBJECT_0:
            try
              if FQueue.Count >= 2 then
              begin
                Merge := TSortFactorySingleton.GetInstance.GetMerger(Self, [FQueue.Dequeue, FQueue.Dequeue]);
                Merge.Start;
                FMerges.Add(Merge);
              end;
            finally
              ReleaseMutex(FMutex);
            end;
          WAIT_TIMEOUT:
            Continue;
        else
          Break;
        end;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

{$ENDREGION}
{$REGION 'Merger'}

procedure TMerger.SetDscFileName(const Value: string);
begin
  FDscFileName := Value;
end;

procedure TMerger.SetLeftFileName(const Value: string);
begin
  FLeftFileName := Value;
end;

procedure TMerger.SetRightFileName(const Value: string);
begin
  FRightFileName := Value;
end;

procedure TMerger.Start;
begin
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        MergeFiles;
      finally
        FMergeController.HasDone;
      end;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

constructor TMerger.Create;
begin
  inherited;
  FRightStringList := TQueueList<AnsiString>.Create;
  FLeftStringList  := TQueueList<AnsiString>.Create;
  FMergeStringList := TList<AnsiString>.Create;
end;

destructor TMerger.Destroy;
begin
  FreeAndNil(FRightStringList);
  FreeAndNil(FLeftStringList);
  FreeAndNil(FMergeStringList);
  inherited;
end;

procedure TMerger.MergeFiles;
  procedure Merge(Left, Right: IFileReader; Writer: IFileWriter);
  var
    LStr, RStr                        : AnsiString;
    LIsReadingString, RIsReadingString: Boolean;
    ReadBytes                         : Integer;
  begin
    ReadBytes        := 0;
    LIsReadingString := (Left.ToRead(FLeftStringList) <> 0) and FLeftStringList.Pop(LStr);
    RIsReadingString := (Right.ToRead(FRightStringList) <> 0) and FRightStringList.Pop(RStr);

    while LIsReadingString and RIsReadingString do
    begin
      if CompareShortString(LStr, RStr) < 0 then
      begin
        FMergeStringList.Add(LStr);
        if FLeftStringList.Count = 0 then
          LIsReadingString := (Left.ToRead(FLeftStringList) <> 0) and FLeftStringList.Pop(LStr)
        else
          LIsReadingString := FLeftStringList.Pop(LStr);
        Inc(ReadBytes, Length(LStr));
      end
      else
      begin
        FMergeStringList.Add(RStr);
        if FRightStringList.Count = 0 then
          RIsReadingString := (Right.ToRead(FRightStringList) <> 0) and FRightStringList.Pop(RStr)
        else
          RIsReadingString := FRightStringList.Pop(RStr);
        Inc(ReadBytes, Length(RStr));
      end;
      if ReadBytes >= MERGE_WRITER_BUFFER_SIZE then
      begin
        Writer.ToWrite(FMergeStringList);
        FMergeStringList.Clear;
        ReadBytes := 0;
      end;
    end;

    while LIsReadingString do
    begin
      FMergeStringList.Add(LStr);

      if FLeftStringList.Count = 0 then
        LIsReadingString := (Left.ToRead(FLeftStringList) <> 0) and FLeftStringList.Pop(LStr)
      else
        LIsReadingString := FLeftStringList.Pop(LStr);

      Inc(ReadBytes, Length(LStr));

      if ReadBytes >= MERGE_WRITER_BUFFER_SIZE then
      begin
        Writer.ToWrite(FMergeStringList);
        FMergeStringList.Clear;
        ReadBytes := 0;
      end;
    end;

    while RIsReadingString do
    begin
      FMergeStringList.Add(RStr);
      if FRightStringList.Count = 0 then
        RIsReadingString := (Right.ToRead(FRightStringList) <> 0) and FRightStringList.Pop(RStr)
      else
        RIsReadingString := FRightStringList.Pop(RStr);

      Inc(ReadBytes, Length(RStr));

      if ReadBytes >= MERGE_WRITER_BUFFER_SIZE then
      begin
        Writer.ToWrite(FMergeStringList);
        FMergeStringList.Clear;
        ReadBytes := 0;
      end;
    end;

    if FMergeStringList.Count > 0 then
    begin
      Writer.ToWrite(FMergeStringList);
      FMergeStringList.Clear;
    end;
  end;

var
  Left, Right  : IFileReader;
  Writer       : IFileWriter;
  MergeFileName: string;
begin
  Left := TFileReader.Create(MERGE_READER_BUFFER_SIZE) as IFileReader;
  Left.Open(FLeftFileName);
  try
    Right := TFileReader.Create(MERGE_READER_BUFFER_SIZE) as IFileReader;
    Right.Open(FRightFileName);
    try
      MergeFileName := TFileWriter.MakeRandomFileName;
      Writer        := TFileWriter.Create(Right.FileSize + Left.FileSize, MERGE_WRITER_BUFFER_SIZE) as IFileWriter;
      Writer.Open(MergeFileName);
      try

        Merge(Left, Right, Writer);
        if (Right.FileSize + Left.FileSize = FMergeController.FSrcFileReader.FileSize) then
        begin
          // Закончить сортировку
          Stop;
          // Остановить таймер
          PostMessage(Application.MainFormHandle, WM_SORT_HAS_FINISHED, 0, 0);
        end
        else
          // Отправить файл для слияния
          while not HasStopped do
            if FMergeController.Add(MergeFileName) then
              Break;
      finally
        Writer.Close;
      end;
    finally
      Right.Close;
      DeleteFile(FRightFileName)
    end;
  finally
    Left.Close;
    DeleteFile(FLeftFileName);
  end;
  if HasStopped then
    // Переименовать файл
    RenameFile(MergeFileName, FMergeController.DscFileName);
end;
{$ENDREGION}
{ TQueueList<T> }

function TQueueList<T>.Pop(var AItem: T): Boolean;
begin
  if Count > 0 then
  begin
    AItem := Items[0];
    Delete(0);
    Result := True;
  end
  else
    Result := False;
end;

end.
