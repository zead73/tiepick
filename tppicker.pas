unit tppicker;

{ Far-style single-pane file picker: blue panel, keyboard first.
  The edit line at the bottom works like Far's command line: typing goes
  there, Up/Down/PgUp/PgDn always drive the panel. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Controls, Forms, StdCtrls, ExtCtrls, Menus,
  Dialogs, LCLType, Masks, LazUTF8, BaseUnix, Unix, unixutil, DateUtils, tpdbus;

type
  TEntry = record
    Name: string;
    IsDir, IsUp, Sel: Boolean;
    Size: Int64;
    MTime: TDateTime;
  end;
  TEntries = array of TEntry;

  { TFarList }

  TFarList = class(TCustomControl)
  private
    FItems: TEntries;
    FCur, FScroll, FRowH: Integer;
    FTitle: string;
    FOnActivate, FOnUserMove: TNotifyEvent;
    FFilesOnly: Boolean;
    function ListTop: Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetItems(const AItems: TEntries; const ATitle: string; ACur: Integer);
    function VisRows: Integer;
    function Count: Integer;
    function Current: Integer;
    function Item(I: Integer): TEntry;
    procedure SetCur(AValue: Integer);
    procedure MoveCur(Delta: Integer);
    procedure ToggleSel(I: Integer);
    procedure SelectAll(Value: Boolean);
    function SelCount: Integer;
    property FilesOnly: Boolean read FFilesOnly write FFilesOnly;
    property OnActivate: TNotifyEvent read FOnActivate write FOnActivate;
    property OnUserMove: TNotifyEvent read FOnUserMove write FOnUserMove;
  end;

  { TPickerForm }

  TPickerForm = class(TForm)
  private
    FReq: TPickRequest;
    FList: TFarList;
    FEdit: TEdit;
    FBar: TPaintBox;
    FDir: string;
    FShowHidden: Boolean;
    FFilters: array of TPickFilter;
    FFilter: Integer;
    FPlaces: TStringList;
    FResult: TStringList;
    FSaveMode: Boolean;
    FNavigated: Boolean;      { highlight moved by the user since last typing/dir change }
    procedure UserMoved(Sender: TObject);
    procedure LoadDir(const ADir: string; const Focus: string = '');
    function Matches(const AName: string): Boolean;
    function Resolve(const Txt: string): string;
    procedure GoUp;
    procedure NextFilter;
    procedure ShowPlaces;
    procedure PlaceClick(Sender: TObject);
    procedure MakeDir;
    procedure EnterPressed;
    procedure ActivateCur(Sender: TObject);
    procedure TryText;
    procedure FinishSelection;
    function FinishWith(const Path: string): Boolean;
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditChange(Sender: TObject);
    procedure BarPaint(Sender: TObject);
  public
    constructor CreateFor(AOwner: TComponent; const AReq: TPickRequest);
    destructor Destroy; override;
  end;

{ Run the picker modally. True = accepted, Uris filled. }
function RunPicker(const Req: TPickRequest; Uris: TStringList): Boolean;

implementation

var
  CBg, CFrame, CFile, CDir, CCur, CCurText, CSel, CCurSel, CHead: TColor;

{ Local modification time. FindFirst's timestamp (and DateUtils) apply today's
  UTC offset to every date, which is an hour off for dates in the other half
  of the DST year; GetLocalTimezone looks the offset up for that date. }
function LocalMTime(const Path: string): TDateTime;
var
  st: Stat;
begin
  Result := 0;
  if FpStat(Path, st) <> 0 then
    if FpLStat(Path, st) <> 0 then Exit;
  Result := UnixToDateTime(st.st_mtime);
  if (st.st_mtime >= 0) and (st.st_mtime <= High(LongInt)) then
  begin
    GetLocalTimezone(cint(st.st_mtime));
    Result := Result + TZSeconds / 86400;
  end;
end;

function FmtSize(N: Int64): string;
begin
  if N < 1024 then Result := IntToStr(N) + ' B'
  else if N < 1024 * 1024 then Result := Format('%.1f KiB', [N / 1024])
  else if N < Int64(1024) * 1024 * 1024 then Result := Format('%.1f MiB', [N / (1024 * 1024)])
  else Result := Format('%.1f GiB', [N / (Int64(1024) * 1024 * 1024)]);
end;

{ TFarList }

constructor TFarList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Font.Name := 'JetBrains Mono';
  Font.Size := 11;
  FRowH := 20;
  TabStop := False;
  ControlStyle := ControlStyle + [csOpaque];
end;

function TFarList.ListTop: Integer;
begin
  Result := 6 + 8 + FRowH + 6;
end;

function TFarList.VisRows: Integer;
begin
  Result := (Height - 6 - 8 - ListTop) div FRowH;
  if Result < 1 then Result := 1;
end;

function TFarList.Count: Integer;
begin
  Result := Length(FItems);
end;

function TFarList.Current: Integer;
begin
  Result := FCur;
end;

function TFarList.Item(I: Integer): TEntry;
begin
  Result := FItems[I];
end;

procedure TFarList.SetItems(const AItems: TEntries; const ATitle: string; ACur: Integer);
begin
  FItems := AItems;
  FTitle := ATitle;
  FScroll := 0;
  FCur := 0;
  SetCur(ACur);
  Invalidate;
end;

procedure TFarList.SetCur(AValue: Integer);
begin
  if AValue >= Count then AValue := Count - 1;
  if AValue < 0 then AValue := 0;
  FCur := AValue;
  if FCur < FScroll then FScroll := FCur
  else if FCur >= FScroll + VisRows then FScroll := FCur - VisRows + 1;
  if FScroll < 0 then FScroll := 0;
  Invalidate;
end;

procedure TFarList.MoveCur(Delta: Integer);
begin
  SetCur(FCur + Delta);
end;

procedure TFarList.ToggleSel(I: Integer);
begin
  if (I < 0) or (I >= Count) or FItems[I].IsUp then Exit;
  if FItems[I].IsDir = FFilesOnly then Exit;
  FItems[I].Sel := not FItems[I].Sel;
  Invalidate;
end;

procedure TFarList.SelectAll(Value: Boolean);
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
    FItems[i].Sel := Value and not FItems[i].IsUp;
  Invalidate;
end;

function TFarList.SelCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Count - 1 do
    if FItems[i].Sel then Inc(Result);
end;

procedure TFarList.Paint;
var
  fr: TRect;
  row, idx, y, xRight, xMod, xSize, sizeW, xName, tw: Integer;
  e: TEntry;
  s, t: string;
  isCur: Boolean;
begin
  Canvas.Font.Assign(Font);
  FRowH := Canvas.TextHeight('Ag') + 3;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := CBg;
  Canvas.FillRect(ClientRect);

  fr := Rect(6, 6, Width - 6, Height - 6);
  Canvas.Pen.Color := CFrame;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(fr);
  Canvas.Rectangle(fr.Left + 3, fr.Top + 3, fr.Right - 3, fr.Bottom - 3);

  xRight := fr.Right - 10;
  xMod := xRight - Canvas.TextWidth('0000-00-00 00:00');
  sizeW := Canvas.TextWidth('<UP--DIR>');
  xSize := xMod - 20 - sizeW;
  xName := fr.Left + 12;

  { column separators }
  Canvas.Pen.Color := CFrame;
  Canvas.Line(xSize - 8, fr.Top + 3, xSize - 8, fr.Bottom - 3);
  Canvas.Line(xMod - 8, fr.Top + 3, xMod - 8, fr.Bottom - 3);
  y := ListTop - 4;
  Canvas.Line(fr.Left + 3, y, fr.Right - 3, y);

  { headers }
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := CHead;
  Canvas.TextOut(xName + (xSize - 8 - xName - Canvas.TextWidth('Name')) div 2, 6 + 8, 'Name');
  Canvas.TextOut(xSize + (xMod - 8 - xSize - Canvas.TextWidth('Size')) div 2, 6 + 8, 'Size');
  Canvas.TextOut(xMod + (xRight - xMod - Canvas.TextWidth('Modified')) div 2, 6 + 8, 'Modified');

  { title on the top border }
  t := FTitle;
  while (UTF8Length(t) > 4) and (Canvas.TextWidth(' ' + t + ' ') > Width - 60) do
    t := UTF8Copy(t, 2, UTF8Length(t));
  if t <> FTitle then t := '…' + t;
  tw := Canvas.TextWidth(' ' + t + ' ');
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := CBg;
  Canvas.Font.Color := clWhite;
  Canvas.TextOut((Width - tw) div 2, fr.Top - Canvas.TextHeight('A') div 2, ' ' + t + ' ');

  { rows }
  for row := 0 to VisRows - 1 do
  begin
    idx := FScroll + row;
    if idx >= Count then Break;
    e := FItems[idx];
    y := ListTop + row * FRowH;
    isCur := idx = FCur;
    if isCur then
    begin
      Canvas.Brush.Color := CCur;
      Canvas.FillRect(fr.Left + 5, y, fr.Right - 5, y + FRowH);
    end;
    Canvas.Brush.Style := bsClear;
    if isCur then
      if e.Sel then Canvas.Font.Color := CCurSel else Canvas.Font.Color := CCurText
    else if e.Sel then Canvas.Font.Color := CSel
    else if e.IsDir then Canvas.Font.Color := CDir
    else Canvas.Font.Color := CFile;
    if e.IsDir then Canvas.Font.Style := [fsBold] else Canvas.Font.Style := [];

    Canvas.TextRect(Rect(xName, y, xSize - 10, y + FRowH), xName, y + 1, e.Name);
    if e.IsUp then s := '<UP--DIR>'
    else if e.IsDir then s := '<DIR>'
    else s := FmtSize(e.Size);
    Canvas.TextOut(xSize + sizeW - Canvas.TextWidth(s), y + 1, s);
    if not e.IsUp then
      Canvas.TextOut(xMod, y + 1, FormatDateTime('yyyy-mm-dd hh:nn', e.MTime));
  end;
  Canvas.Font.Style := [];
end;

procedure TFarList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  r: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Y < ListTop then Exit;
  r := FScroll + (Y - ListTop) div FRowH;
  if r < Count then SetCur(r);
  if Assigned(FOnUserMove) then FOnUserMove(Self);
end;

procedure TFarList.DblClick;
begin
  inherited DblClick;
  if Assigned(FOnActivate) then FOnActivate(Self);
end;

function TFarList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  FScroll := FScroll - (WheelDelta div 120) * 3;
  if FScroll > Count - VisRows then FScroll := Count - VisRows;
  if FScroll < 0 then FScroll := 0;
  Invalidate;
  Result := True;
end;

{ TPickerForm }

function UnixHome: string;
begin
  Result := GetEnvironmentVariable('HOME');
  if Result = '' then Result := '/';
end;

constructor TPickerForm.CreateFor(AOwner: TComponent; const AReq: TPickRequest);
var
  i: Integer;
  allf: TPickFilter;
  startDir, nm: string;
begin
  inherited CreateNew(AOwner);
  FReq := AReq;
  FResult := TStringList.Create;
  FPlaces := TStringList.Create;
  FSaveMode := (FReq.Method = 'SaveFile');

  { filters + implicit "All files" }
  SetLength(FFilters, Length(FReq.Filters));
  for i := 0 to High(FReq.Filters) do FFilters[i] := FReq.Filters[i];
  allf.Name := 'All files (*)';
  SetLength(allf.Patterns, 1);
  allf.Patterns[0] := '*';
  SetLength(FFilters, Length(FFilters) + 1);
  FFilters[High(FFilters)] := allf;
  FFilter := FReq.CurrentFilter;
  if (FFilter < 0) or (FFilter > High(FFilters)) then
    if Length(FReq.Filters) > 0 then FFilter := 0 else FFilter := High(FFilters);

  Caption := FReq.Title;
  if Caption = '' then Caption := 'tiepick';
  Position := poScreenCenter;
  Width := 960;
  Height := 680;
  Color := CBg;
  KeyPreview := True;
  OnKeyDown := @FormKey;

  FBar := TPaintBox.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alBottom;
  FBar.Height := 26;
  FBar.OnPaint := @BarPaint;
  FBar.Font.Name := 'JetBrains Mono';
  FBar.Font.Size := 10;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.Align := alBottom;
  FEdit.Font.Name := 'JetBrains Mono';
  FEdit.Font.Size := 11;
  FEdit.Color := clBlack;
  FEdit.Font.Color := RGBToColor(200, 200, 200);
  FEdit.BorderStyle := bsNone;
  FEdit.OnChange := @EditChange;

  FList := TFarList.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.OnActivate := @ActivateCur;
  FList.OnUserMove := @UserMoved;
  FList.FilesOnly := not FReq.Directory;

  { starting folder }
  startDir := FReq.CurrentFolder;
  nm := FReq.CurrentName;
  if (startDir = '') and (FReq.CurrentFile <> '') then
  begin
    startDir := ExtractFileDir(FReq.CurrentFile);
    if nm = '' then nm := ExtractFileName(FReq.CurrentFile);
  end;
  if not DirectoryExists(startDir) then startDir := UnixHome;
  LoadDir(startDir);
  if FSaveMode and (nm <> '') then
  begin
    FEdit.Text := nm;
    FEdit.SelStart := Length(nm);
  end;
  ActiveControl := FEdit;
end;

destructor TPickerForm.Destroy;
begin
  FResult.Free;
  FPlaces.Free;
  inherited Destroy;
end;

function TPickerForm.Matches(const AName: string): Boolean;
var
  i: Integer;
begin
  if FReq.Directory then Exit(False);
  Result := False;
  if (FFilter < 0) or (FFilter > High(FFilters)) then Exit(True);
  with FFilters[FFilter] do
  begin
    if Length(Patterns) = 0 then Exit(True);
    for i := 0 to High(Patterns) do
      if MatchesMask(AName, Patterns[i], False) then Exit(True);
  end;
end;

procedure TPickerForm.LoadDir(const ADir: string; const Focus: string);
var
  dir, full: string;
  sr: TSearchRec;
  raw: TEntries;
  sl: TStringList;
  items: TEntries;
  n, i, at: Integer;
  e: TEntry;
begin
  dir := ExpandFileName(ADir);
  if (Length(dir) > 1) and (dir[Length(dir)] = '/') then SetLength(dir, Length(dir) - 1);
  if dir = '' then dir := '/';
  if not DirectoryExists(dir) then begin Beep; Exit; end;

  SetLength(raw, 0);
  n := 0;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (not FShowHidden) and (sr.Name[1] = '.') then Continue;
      full := IncludeTrailingPathDelimiter(dir) + sr.Name;
      FillChar(e, SizeOf(e), 0);
      e.Name := sr.Name;
      e.IsDir := ((sr.Attr and faDirectory) <> 0) or
        (((sr.Attr and faSymLink) <> 0) and DirectoryExists(full));
      e.Size := sr.Size;
      e.MTime := LocalMTime(full);
      if (not e.IsDir) and (not Matches(e.Name)) then Continue;
      SetLength(raw, n + 1);
      raw[n] := e;
      Inc(n);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end
  else if not DirectoryExists(dir) then
  begin
    Beep;
    Exit;
  end;

  { dirs first, then files, each sorted by name }
  SetLength(items, 0);
  sl := TStringList.Create;
  try
    sl.CaseSensitive := False;
    sl.Sorted := True;
    sl.Duplicates := dupAccept;
    for i := 0 to n - 1 do
      if raw[i].IsDir then sl.AddObject(raw[i].Name, TObject(PtrInt(i)));
    if dir <> '/' then
    begin
      SetLength(items, 1);
      FillChar(items[0], SizeOf(TEntry), 0);
      items[0].Name := '..';
      items[0].IsDir := True;
      items[0].IsUp := True;
    end;
    for i := 0 to sl.Count - 1 do
    begin
      SetLength(items, Length(items) + 1);
      items[High(items)] := raw[PtrInt(sl.Objects[i])];
    end;
    sl.Clear;
    for i := 0 to n - 1 do
      if not raw[i].IsDir then sl.AddObject(raw[i].Name, TObject(PtrInt(i)));
    for i := 0 to sl.Count - 1 do
    begin
      SetLength(items, Length(items) + 1);
      items[High(items)] := raw[PtrInt(sl.Objects[i])];
    end;
  finally
    sl.Free;
  end;

  FDir := dir;
  at := 0;
  if Focus <> '' then
    for i := 0 to High(items) do
      if items[i].Name = Focus then begin at := i; Break; end;
  FList.SetItems(items, dir, at);
  FNavigated := False;
  FBar.Invalidate;
end;

function TPickerForm.Resolve(const Txt: string): string;
begin
  if Txt = '~' then Result := UnixHome
  else if Copy(Txt, 1, 2) = '~/' then Result := UnixHome + Copy(Txt, 2, MaxInt)
  else if Copy(Txt, 1, 1) = '/' then Result := Txt
  else Result := IncludeTrailingPathDelimiter(FDir) + Txt;
  Result := ExpandFileName(Result);
end;

procedure TPickerForm.GoUp;
var
  parentDir: string;
begin
  if FDir = '/' then Exit;
  parentDir := ExtractFileDir(FDir);
  if parentDir = '' then parentDir := '/';
  LoadDir(parentDir, ExtractFileName(FDir));
end;

procedure TPickerForm.NextFilter;
begin
  if Length(FFilters) < 2 then Exit;
  FFilter := (FFilter + 1) mod Length(FFilters);
  LoadDir(FDir);
end;

procedure TPickerForm.PlaceClick(Sender: TObject);
begin
  LoadDir(FPlaces[(Sender as TMenuItem).Tag]);
end;

procedure TPickerForm.ShowPlaces;
var
  pm: TPopupMenu;
  mi: TMenuItem;
  f: TextFile;
  line, mp, bm: string;
  p: Integer;

  procedure Add(const ACaption, APath: string);
  begin
    if (APath = '') or not DirectoryExists(APath) then Exit;
    if FPlaces.IndexOf(APath) >= 0 then Exit;
    FPlaces.Add(APath);
    mi := TMenuItem.Create(pm);
    mi.Caption := ACaption + '   ' + APath;
    mi.Tag := FPlaces.Count - 1;
    mi.OnClick := @PlaceClick;
    pm.Items.Add(mi);
  end;

begin
  FPlaces.Clear;
  pm := TPopupMenu.Create(Self);
  Add('Home', UnixHome);
  Add('Root', '/');
  { mounted data drives }
  AssignFile(f, '/proc/self/mounts');
  {$I-} Reset(f); {$I+}
  if IOResult = 0 then
  begin
    while not Eof(f) do
    begin
      ReadLn(f, line);
      p := Pos(' ', line);
      if p = 0 then Continue;
      mp := Copy(line, p + 1, MaxInt);
      p := Pos(' ', mp);
      if p > 0 then mp := Copy(mp, 1, p - 1);
      mp := StringReplace(mp, '\040', ' ', [rfReplaceAll]);
      if (Copy(mp, 1, 5) = '/mnt/') or (Copy(mp, 1, 7) = '/media/') or
         (Copy(mp, 1, 11) = '/run/media/') then
        Add('Drive', mp);
    end;
    CloseFile(f);
  end;
  { GTK bookmarks }
  AssignFile(f, UnixHome + '/.config/gtk-3.0/bookmarks');
  {$I-} Reset(f); {$I+}
  if IOResult = 0 then
  begin
    while not Eof(f) do
    begin
      ReadLn(f, line);
      p := Pos(' ', line);
      if p > 0 then line := Copy(line, 1, p - 1);
      if Copy(line, 1, 7) = 'file://' then
      begin
        bm := PathOfUri(line);
        Add('Bookmark', bm);
      end;
    end;
    CloseFile(f);
  end;
  pm.PopUp(Left + 40, Top + 60);
end;

procedure TPickerForm.MakeDir;
var
  nm: string;
begin
  nm := '';
  if InputQuery('New folder', 'Name:', nm) and (Trim(nm) <> '') then
  begin
    if CreateDir(IncludeTrailingPathDelimiter(FDir) + Trim(nm)) then
      LoadDir(FDir, Trim(nm))
    else
      Beep;
  end;
end;

function TPickerForm.FinishWith(const Path: string): Boolean;
begin
  FResult.Add(UriOfPath(Path));
  ModalResult := mrOK;
  Result := True;
end;

procedure TPickerForm.TryText;
var
  path: string;
begin
  path := Resolve(Trim(FEdit.Text));
  if DirectoryExists(path) then
  begin
    FEdit.Text := '';
    LoadDir(path);
  end
  else if FSaveMode then
  begin
    if FileExists(path) and
       (MessageDlg('Replace file', ExtractFileName(path) + ' already exists. Replace it?',
         mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
    FinishWith(path);
  end
  else if FileExists(path) and not FReq.Directory then
    FinishWith(path)
  else
    Beep;
end;

procedure TPickerForm.FinishSelection;
var
  i: Integer;
  e: TEntry;
  base: string;
begin
  base := IncludeTrailingPathDelimiter(FDir);
  if FReq.Method = 'SaveFiles' then
  begin
    for i := 0 to High(FReq.Files) do
      FResult.Add(UriOfPath(base + FReq.Files[i]));
    ModalResult := mrOK;
    Exit;
  end;
  if FSaveMode then
  begin
    if Trim(FEdit.Text) <> '' then TryText else Beep;
    Exit;
  end;
  if Trim(FEdit.Text) <> '' then begin TryText; Exit; end;

  if FList.SelCount > 0 then
  begin
    for i := 0 to FList.Count - 1 do
    begin
      e := FList.Item(i);
      if e.Sel and (e.IsDir = FReq.Directory) then FResult.Add(UriOfPath(base + e.Name));
    end;
  end
  else
  begin
    e := FList.Item(FList.Current);
    if e.IsUp then
    begin
      if FReq.Directory then FResult.Add(UriOfPath(FDir));
    end
    else if e.IsDir = FReq.Directory then
      FResult.Add(UriOfPath(base + e.Name));
  end;
  if FResult.Count > 0 then ModalResult := mrOK else Beep;
end;

procedure TPickerForm.ActivateCur(Sender: TObject);
var
  e: TEntry;
begin
  if FList.Count = 0 then Exit;
  e := FList.Item(FList.Current);
  if e.IsUp then GoUp
  else if e.IsDir then LoadDir(IncludeTrailingPathDelimiter(FDir) + e.Name)
  else if FSaveMode then
  begin
    FEdit.Text := e.Name;
    FEdit.SelStart := Length(e.Name);
  end
  else
    FinishSelection;
end;

procedure TPickerForm.UserMoved(Sender: TObject);
begin
  FNavigated := True;
end;

procedure TPickerForm.EnterPressed;
var
  e: TEntry;
begin
  { a highlight the user moved onto a folder wins over the (prefilled) edit text }
  if FNavigated and (FList.Count > 0) then
  begin
    e := FList.Item(FList.Current);
    if e.IsDir then begin ActivateCur(nil); Exit; end;
  end;
  if Trim(FEdit.Text) <> '' then TryText else ActivateCur(nil);
end;

procedure TPickerForm.EditChange(Sender: TObject);
var
  t: string;
  i: Integer;
begin
  { type-ahead: jump to the first entry that starts with the typed text }
  FNavigated := False;
  t := FEdit.Text;
  if FSaveMode or (t = '') or (t[1] in ['/', '~']) then Exit;
  for i := 0 to FList.Count - 1 do
    if (not FList.Item(i).IsUp) and
       (UTF8LowerCase(Copy(FList.Item(i).Name, 1, Length(t))) = UTF8LowerCase(t)) then
    begin
      FList.SetCur(i);
      Break;
    end;
end;

procedure TPickerForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  blank: Boolean;
begin
  blank := FEdit.Text = '';
  case Key of
    VK_UP: begin FList.MoveCur(-1); FNavigated := True; end;
    VK_DOWN: begin FList.MoveCur(1); FNavigated := True; end;
    VK_PRIOR: begin FList.MoveCur(-FList.VisRows); FNavigated := True; end;
    VK_NEXT: begin FList.MoveCur(FList.VisRows); FNavigated := True; end;
    VK_HOME, VK_LEFT: if blank then begin FList.SetCur(0); FNavigated := True; end else Exit;
    VK_END: if blank then begin FList.SetCur(FList.Count - 1); FNavigated := True; end else Exit;
    VK_BACK: if blank then GoUp else Exit;
    VK_RETURN: EnterPressed;
    VK_ESCAPE: if blank then ModalResult := mrCancel else FEdit.Text := '';
    VK_TAB: NextFilter;
    VK_INSERT:
      if FReq.Multiple then
      begin
        FList.ToggleSel(FList.Current);
        FList.MoveCur(1);
        FBar.Invalidate;
      end;
    VK_SPACE:
      if blank and FReq.Multiple then
      begin
        FList.ToggleSel(FList.Current);
        FList.MoveCur(1);
        FBar.Invalidate;
      end
      else Exit;
    VK_A:
      if (ssCtrl in Shift) and FReq.Multiple then
      begin
        FList.SelectAll(True);
        FBar.Invalidate;
      end
      else Exit;
    VK_H:
      if ssCtrl in Shift then
      begin
        FShowHidden := not FShowHidden;
        LoadDir(FDir);
      end
      else Exit;
    VK_F2: ShowPlaces;
    VK_F7: MakeDir;
    VK_F10: FinishSelection;
  else
    Exit;
  end;
  Key := 0;
end;

procedure TPickerForm.BarPaint(Sender: TObject);
var
  c: TCanvas;
  x: Integer;
  info: string;

  procedure Seg(const K, L: string);
  begin
    c.Brush.Color := clBlack;
    c.Font.Color := RGBToColor(192, 192, 192);
    c.TextOut(x, 3, K);
    Inc(x, c.TextWidth(K));
    c.Brush.Color := CCur;
    c.Font.Color := clBlack;
    c.TextOut(x, 3, L + ' ');
    Inc(x, c.TextWidth(L + ' ') + 6);
  end;

begin
  c := FBar.Canvas;
  c.Font.Assign(FBar.Font);
  c.Brush.Color := clBlack;
  c.FillRect(0, 0, FBar.Width, FBar.Height);
  x := 4;
  Seg('F2', 'Places');
  Seg('F7', 'MkDir');
  if FReq.Method = 'SaveFiles' then Seg('F10', 'Save here')
  else if FSaveMode then Seg('F10', 'Save')
  else if FReq.AcceptLabel <> '' then Seg('F10', StringReplace(FReq.AcceptLabel, '_', '', []))
  else Seg('F10', 'Select');
  if Length(FFilters) > 1 then Seg('Tab', 'Filter');
  Seg('^H', 'Hidden');
  if FReq.Multiple then Seg('Ins', 'Mark');
  Seg('Esc', 'Cancel');

  info := '';
  if (FFilter >= 0) and (FFilter <= High(FFilters)) and not FReq.Directory then
    info := FFilters[FFilter].Name;
  if FReq.Multiple and (FList.SelCount > 0) then
    info := Format('%d marked  ', [FList.SelCount]) + info;
  c.Brush.Color := clBlack;
  c.Font.Color := RGBToColor(255, 255, 85);
  c.TextOut(FBar.Width - c.TextWidth(info) - 8, 3, info);
end;

function RunPicker(const Req: TPickRequest; Uris: TStringList): Boolean;
var
  f: TPickerForm;
begin
  f := TPickerForm.CreateFor(Application, Req);
  try
    Result := f.ShowModal = mrOK;
    if Result then Uris.AddStrings(f.FResult);
  finally
    f.Free;
  end;
end;

initialization
  CBg := RGBToColor(0, 0, 170);
  CFrame := RGBToColor(170, 170, 170);
  CFile := RGBToColor(85, 255, 255);
  CDir := RGBToColor(255, 255, 255);
  CCur := RGBToColor(0, 170, 170);
  CCurText := RGBToColor(0, 0, 0);
  CSel := RGBToColor(255, 255, 85);
  CCurSel := RGBToColor(128, 0, 0);
  CHead := RGBToColor(255, 255, 85);

end.
