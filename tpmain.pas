unit tpmain;

{ Invisible main form: polls the session bus and runs a picker per request. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, ExtCtrls, tpdbus, tppicker;

const
  IdleSeconds = 600;

type
  TMainForm = class(TForm)
  private
    FTimer: TTimer;
    FService: TPortalService;
    FLastActive: TDateTime;
    procedure Tick(Sender: TObject);
    function Pick(const Req: TPickRequest; Uris: TStringList): Boolean;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

constructor TMainForm.Create(TheOwner: TComponent);
begin
  inherited CreateNew(TheOwner);
  FLastActive := Now;
  FService := TPortalService.Create(@Pick);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 30;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := True;
end;

destructor TMainForm.Destroy;
begin
  FService.Free;
  inherited Destroy;
end;

function TMainForm.Pick(const Req: TPickRequest; Uris: TStringList): Boolean;
begin
  Result := RunPicker(Req, Uris);
  FLastActive := Now;
end;

procedure TMainForm.Tick(Sender: TObject);
begin
  FTimer.Enabled := False;       { no re-entry while a picker is modal }
  try
    if not FService.Poll then
      Application.Terminate
    else if (Now - FLastActive) * 86400 > IdleSeconds then
      Application.Terminate;
  finally
    FTimer.Enabled := True;
  end;
end;

end.
