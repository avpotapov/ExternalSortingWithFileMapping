unit ExtSortForm;

interface
{$REGION 'Описание модуля'}
 (*
  *  Модуль формы сортировки
  *
  *  Основная процедура Sort
  *  Вначале происходит инициализация процесса сортировки
  *  Далее создается менеджер слияния.
  *  Файл разбивается на части соответсвующие количеству процессоров
  *  Каждая часть файла передается SeriesCreator, который также создается.
  *  Для создания сложных объектов MergeController, SeriesCreator используются фабрики
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
  *  В объекте сляния происходит лияние двух файлов в один, используя функцию слияния.
  *  Если размер файла соответствует размеру неотсортированного файла, то цель достигнута.
  *  Сортировка прекращается.
  *  В противном случае файл передается контроллеру слияния
  *)
{$ENDREGION}
{$REGION 'uses'}

uses
  Winapi.Windows,
  Winapi.Messages,

  System.SysUtils,
  System.Variants,
  System.Classes,
  System.DateUtils,

  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.ComCtrls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ImgList,
  Vcl.ExtDlgs,

  System.UITypes,
  System.Diagnostics,
  System.Generics.Collections,
  System.Generics.Defaults,

  ExtSortFile,
  ExtSortThread,
  System.ImageList, ExtSortFactory;

{$ENDREGION}

type
  TMainForm = class(TForm)
    SrcButtonedEdit: TButtonedEdit;
    SortButton: TButton;
    DscButtonedEdit: TButtonedEdit;
    SrcLabel: TLabel;
    DestLabel: TLabel;
    StatusBar: TStatusBar;
    ImageList: TImageList;
    SaveTextFileDialog: TSaveTextFileDialog;
    OpenTextFileDialog: TOpenTextFileDialog;
    Timer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure SortButtonClick(Sender: TObject);
    procedure SrcButtonedEditRightButtonClick(Sender: TObject);
    procedure DscButtonedEditRightButtonClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure TimerTimer(Sender: TObject);
  private
    FSeriesPool     : TList<ISort>;
    FMergeController: IMergeController;
    FTime           : TTime;
    // Основная процедура
    procedure Sort;
    procedure WmSortFinished(var Message: TMessage); message WM_SORT_HAS_FINISHED;
  public
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}
{$IFDEF DEBUG}

uses SimpleLogger;
{$ENDIF}
{$REGION 'StatusBarHelper - StatusInfo'}

type
  TStatusBarHelper = class Helper for TStatusBar
  public
    procedure SetInfo(const AMsg: string);
    procedure ElapsedTime(const ATime: TTime);
  end;

procedure TStatusBarHelper.ElapsedTime(const ATime: TTime);
begin
  Panels[1].Text := FormatDateTime('hh:nn:ss', ATime);
end;

procedure TStatusBarHelper.SetInfo(const AMsg: string);
begin
  Panels[0].Text := AMsg;
end;

{$ENDREGION}

procedure TMainForm.SortButtonClick(Sender: TObject);
begin
  StatusBar.SetInfo('Сортировка ...');
  try
    // Запустить сортировку
    Sort;
    SortButton.Enabled := False;
  except
    on E: Exception do
      StatusBar.SetInfo(Format('ОШИБКА: %s', [E.Message]));
  end;
end;

procedure TMainForm.SrcButtonedEditRightButtonClick(Sender: TObject);
begin
  // Файла - источник
  if OpenTextFileDialog.Execute then
  begin
    SrcButtonedEdit.Text := OpenTextFileDialog.FileName;
    StatusBar.SetInfo(Format('Файл - источник: %s', [SrcButtonedEdit.Text]));
  end;
end;

procedure TMainForm.DscButtonedEditRightButtonClick(Sender: TObject);
begin
  // Файл - приемник
  if SaveTextFileDialog.Execute then
  begin
    DscButtonedEdit.Text := SaveTextFileDialog.FileName;
    StatusBar.SetInfo(Format('Файл - приемник: %s', [DscButtonedEdit.Text]));
  end;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FreeAndNil(FSeriesPool);
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
 SortFactory: ISortFactorySingleton;
begin
  // Фабрика объектов сортировки: серии, слияние
  SortFactory                      := TSortFactorySingleton.GetInstance;
  SortFactory.SeriesCreatorClass   := TSeriesCreator;
  SortFactory.MergerClass          := TMerger;
  SortFactory.MergeControllerClass := TMergeController;

  // Пул потоков  создания серий
  FSeriesPool := TList<ISort>.Create;
end;

procedure TMainForm.TimerTimer(Sender: TObject);
begin
  FTime := IncSecond(FTime, 1);
  StatusBar.ElapsedTime(FTime);
end;

procedure TMainForm.WmSortFinished(var Message: TMessage);
begin
  StatusBar.SetInfo('Сортировка закончена');
  Timer.Enabled := False;
  SortButton.Enabled := True;
end;

procedure TMainForm.Sort;
var
  Series     : ISort;
  Reader     : IFileReader;
  I          : Integer;
  L, H       : Int64;
begin
  // Инициализация сортировки (FStop = 0)
  FSeriesPool.Clear;
  FMergeController := nil;
  FTime         := 0;
  Timer.Enabled := True;
  TAbstractSort.Initialize;

  // Имена файлов
  TSortFactorySingleton.GetInstance.SrcFileName := SrcButtonedEdit.Text;
  TSortFactorySingleton.GetInstance.DscFileName := DscButtonedEdit.Text;

  Reader := TSortFactorySingleton.GetInstance.GetReader(SrcButtonedEdit.Text);

  // Контроллер слияния
  FMergeController := TSortFactorySingleton.GetInstance.GetMergerController(Reader, DscButtonedEdit.Text);
  FMergeController.Start;

  for I := 0 to NUMBER_PROCESSOR - 1 do
  begin
    Series := TSortFactorySingleton.GetInstance.GetSeriesCreator(Reader, FMergeController);
    Series.Start;
    FSeriesPool.Add(Series);
  end;
end;

end.
