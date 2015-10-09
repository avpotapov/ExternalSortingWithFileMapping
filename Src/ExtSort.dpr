program ExtSort;

uses
  Vcl.Forms,
{$IFDEF DEBUG}
  SimpleLogger in 'SimpleLogger.pas',
{$ENDIF}
  ExtSortForm in 'ExtSortForm.pas',
  ExtSortFile in 'ExtSortFile.pas',
  ExtSortFactory in 'ExtSortFactory.pas',
  ExtSortThread in 'ExtSortThread.pas';

{$R *.res}

begin
  Application.Initialize;
{$REGION 'Debug'}
{$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
{$ENDIF}
{$ENDREGION}
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;

end.
