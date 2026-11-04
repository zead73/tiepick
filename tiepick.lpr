program tiepick;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, tpdbus, tppicker, tpmain;

begin
  Application.Scaled := True;
  Application.Initialize;
  Application.ShowMainForm := False;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
