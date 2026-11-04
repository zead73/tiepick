unit tpdbus;

{ Minimal xdg-desktop-portal FileChooser backend over libdbus.
  Answers org.freedesktop.impl.portal.FileChooser methods OpenFile, SaveFile and SaveFiles. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, dbus;

const
  BusName = 'org.freedesktop.impl.portal.desktop.tiepick';
  ImplInterface = 'org.freedesktop.impl.portal.FileChooser';

type
  TPickFilter = record
    Name: string;
    Patterns: array of string;   { glob patterns only; MIME entries are ignored }
  end;

  TPickRequest = record
    Method, AppId, Title: string;
    Multiple, Directory: Boolean;
    AcceptLabel, CurrentName, CurrentFolder, CurrentFile: string;
    Filters: array of TPickFilter;
    CurrentFilter: Integer;       { -1 = none }
    Files: array of string;       { SaveFiles }
  end;

  { Return True when the user accepted; fill Uris with file:// URIs. }
  TPickHandler = function(const Req: TPickRequest; Uris: TStringList): Boolean of object;

  TPortalService = class
  private
    FConn: PDBusConnection;
    FHandler: TPickHandler;
    procedure HandleMessage(Msg: PDBusMessage);
    procedure ReplyPick(Msg: PDBusMessage; Response: cuint; Uris: TStringList);
    procedure ReplyError(Msg: PDBusMessage; const Name, Text: string);
    procedure ReplyEmptyDict(Msg: PDBusMessage);
    procedure HandlePick(Msg: PDBusMessage; const Member: string);
  public
    constructor Create(AHandler: TPickHandler);
    { Process everything currently queued. False if the bus connection died. }
    function Poll: Boolean;
  end;

function UriOfPath(const Path: string): string;
function PathOfUri(const Uri: string): string;

implementation

function SafeStr(P: PChar): string;
begin
  if P = nil then Result := '' else Result := string(P);
end;

function UriOfPath(const Path: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := 'file://';
  for i := 1 to Length(Path) do
  begin
    c := Path[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/'] then
      Result += c
    else
      Result += '%' + IntToHex(Ord(c), 2);
  end;
end;

function PathOfUri(const Uri: string): string;
var
  s: string;
  i: Integer;
begin
  s := Uri;
  if Copy(s, 1, 7) = 'file://' then Delete(s, 1, 7);
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if (s[i] = '%') and (i + 2 <= Length(s)) then
    begin
      Result += Chr(StrToIntDef('$' + Copy(s, i + 1, 2), 63));
      Inc(i, 3);
    end
    else
    begin
      Result += s[i];
      Inc(i);
    end;
  end;
end;

{ ---- message parsing ---------------------------------------------------- }

function IterString(It: PDBusMessageIter): string;
var
  p: PChar;
begin
  p := nil;
  dbus_message_iter_get_basic(It, @p);
  Result := SafeStr(p);
end;

function IterBytesAsString(It: PDBusMessageIter): string;
var
  sub: DBusMessageIter;
  b: Byte;
begin
  Result := '';
  dbus_message_iter_recurse(It, @sub);
  while dbus_message_iter_get_arg_type(@sub) = DBUS_TYPE_BYTE do
  begin
    b := 0;
    dbus_message_iter_get_basic(@sub, @b);
    if b <> 0 then Result += Chr(b);       { drop the trailing NUL }
    dbus_message_iter_next(@sub);
  end;
end;

procedure ParseFilters(V: PDBusMessageIter; var Req: TPickRequest);
var
  arr, st, pa, ps: DBusMessageIter;
  f: TPickFilter;
  kind: cuint;
begin
  dbus_message_iter_recurse(V, @arr);
  while dbus_message_iter_get_arg_type(@arr) = DBUS_TYPE_STRUCT do
  begin
    dbus_message_iter_recurse(@arr, @st);
    f.Name := IterString(@st);
    SetLength(f.Patterns, 0);
    dbus_message_iter_next(@st);
    dbus_message_iter_recurse(@st, @pa);
    while dbus_message_iter_get_arg_type(@pa) = DBUS_TYPE_STRUCT do
    begin
      dbus_message_iter_recurse(@pa, @ps);
      kind := 0;
      dbus_message_iter_get_basic(@ps, @kind);
      dbus_message_iter_next(@ps);
      if kind = 0 then
      begin
        SetLength(f.Patterns, Length(f.Patterns) + 1);
        f.Patterns[High(f.Patterns)] := IterString(@ps);
      end;
      dbus_message_iter_next(@pa);
    end;
    SetLength(Req.Filters, Length(Req.Filters) + 1);
    Req.Filters[High(Req.Filters)] := f;
    dbus_message_iter_next(@arr);
  end;
end;

procedure ParseOptions(Dict: PDBusMessageIter; var Req: TPickRequest);
var
  ent, v: DBusMessageIter;
  key, curName: string;
  b: dbus_bool_t;
  i: Integer;
begin
  curName := '';
  while dbus_message_iter_get_arg_type(Dict) = DBUS_TYPE_DICT_ENTRY do
  begin
    dbus_message_iter_recurse(Dict, @ent);
    key := IterString(@ent);
    dbus_message_iter_next(@ent);
    dbus_message_iter_recurse(@ent, @v);
    b := 0;
    if key = 'multiple' then
    begin
      dbus_message_iter_get_basic(@v, @b);
      Req.Multiple := b <> 0;
    end
    else if key = 'directory' then
    begin
      dbus_message_iter_get_basic(@v, @b);
      Req.Directory := b <> 0;
    end
    else if key = 'accept_label' then
      Req.AcceptLabel := IterString(@v)
    else if key = 'current_name' then
      Req.CurrentName := IterString(@v)
    else if key = 'current_folder' then
      Req.CurrentFolder := IterBytesAsString(@v)
    else if key = 'current_file' then
      Req.CurrentFile := IterBytesAsString(@v)
    else if key = 'filters' then
      ParseFilters(@v, Req)
    else if key = 'current_filter' then
    begin
      { (sa(us)) -- match by name }
      dbus_message_iter_recurse(@v, @ent);
      curName := IterString(@ent);
    end
    else if key = 'files' then
    begin
      { aay }
      dbus_message_iter_recurse(@v, @ent);
      while dbus_message_iter_get_arg_type(@ent) = DBUS_TYPE_ARRAY do
      begin
        SetLength(Req.Files, Length(Req.Files) + 1);
        Req.Files[High(Req.Files)] := IterBytesAsString(@ent);
        dbus_message_iter_next(@ent);
      end;
    end;
    dbus_message_iter_next(Dict);
  end;
  Req.CurrentFilter := -1;
  if curName <> '' then
    for i := 0 to High(Req.Filters) do
      if Req.Filters[i].Name = curName then
        Req.CurrentFilter := i;
end;

{ ---- replies ------------------------------------------------------------ }

procedure TPortalService.ReplyPick(Msg: PDBusMessage; Response: cuint; Uris: TStringList);
var
  rep: PDBusMessage;
  it, arr, ent, vr, sa: DBusMessageIter;
  key, s: PChar;
  i: Integer;
  keyStr: string;
begin
  rep := dbus_message_new_method_return(Msg);
  dbus_message_iter_init_append(rep, @it);
  dbus_message_iter_append_basic(@it, DBUS_TYPE_UINT32, @Response);
  dbus_message_iter_open_container(@it, DBUS_TYPE_ARRAY, '{sv}', @arr);
  if (Response = 0) and (Uris.Count > 0) then
  begin
    dbus_message_iter_open_container(@arr, DBUS_TYPE_DICT_ENTRY, nil, @ent);
    keyStr := 'uris';
    key := PChar(keyStr);
    dbus_message_iter_append_basic(@ent, DBUS_TYPE_STRING, @key);
    dbus_message_iter_open_container(@ent, DBUS_TYPE_VARIANT, 'as', @vr);
    dbus_message_iter_open_container(@vr, DBUS_TYPE_ARRAY, 's', @sa);
    for i := 0 to Uris.Count - 1 do
    begin
      s := PChar(Uris[i]);
      dbus_message_iter_append_basic(@sa, DBUS_TYPE_STRING, @s);
    end;
    dbus_message_iter_close_container(@vr, @sa);
    dbus_message_iter_close_container(@ent, @vr);
    dbus_message_iter_close_container(@arr, @ent);
  end;
  dbus_message_iter_close_container(@it, @arr);
  dbus_connection_send(FConn, rep, nil);
  dbus_connection_flush(FConn);
  dbus_message_unref(rep);
end;

procedure TPortalService.ReplyError(Msg: PDBusMessage; const Name, Text: string);
var
  rep: PDBusMessage;
begin
  rep := dbus_message_new_error(Msg, PChar(Name), PChar(Text));
  dbus_connection_send(FConn, rep, nil);
  dbus_connection_flush(FConn);
  dbus_message_unref(rep);
end;

procedure TPortalService.ReplyEmptyDict(Msg: PDBusMessage);
var
  rep: PDBusMessage;
  it, arr: DBusMessageIter;
begin
  rep := dbus_message_new_method_return(Msg);
  dbus_message_iter_init_append(rep, @it);
  dbus_message_iter_open_container(@it, DBUS_TYPE_ARRAY, '{sv}', @arr);
  dbus_message_iter_close_container(@it, @arr);
  dbus_connection_send(FConn, rep, nil);
  dbus_connection_flush(FConn);
  dbus_message_unref(rep);
end;

{ ---- dispatch ----------------------------------------------------------- }

procedure TPortalService.HandlePick(Msg: PDBusMessage; const Member: string);
var
  it, dict: DBusMessageIter;
  req: TPickRequest;
  uris: TStringList;
  ok: Boolean;
begin
  FillChar(req, SizeOf(req), 0);
  req.Method := Member;
  req.CurrentFilter := -1;
  if dbus_message_iter_init(Msg, @it) = 0 then
  begin
    ReplyError(Msg, 'org.freedesktop.DBus.Error.InvalidArgs', 'no arguments');
    Exit;
  end;
  dbus_message_iter_next(@it);                 { handle (o) }
  req.AppId := IterString(@it);
  dbus_message_iter_next(@it);
  dbus_message_iter_next(@it);                 { parent_window }
  req.Title := IterString(@it);
  dbus_message_iter_next(@it);
  if dbus_message_iter_get_arg_type(@it) = DBUS_TYPE_ARRAY then
  begin
    dbus_message_iter_recurse(@it, @dict);     { into the options dict }
    ParseOptions(@dict, req);
  end;

  if GetEnvironmentVariable('TIEPICK_DEBUG') <> '' then
    WriteLn(StdErr, Format('%s app=%s title=%s multi=%s dir=%s folder=[%s] file=[%s] name=[%s] filters=%d cur=%d',
      [req.Method, req.AppId, req.Title, BoolToStr(req.Multiple, True), BoolToStr(req.Directory, True),
       req.CurrentFolder, req.CurrentFile, req.CurrentName, Length(req.Filters), req.CurrentFilter]));
  Flush(StdErr);
  uris := TStringList.Create;
  try
    ok := FHandler(req, uris);
    if ok then
      ReplyPick(Msg, 0, uris)
    else
      ReplyPick(Msg, 1, uris);                 { 1 = cancelled by user }
  finally
    uris.Free;
  end;
end;

procedure TPortalService.HandleMessage(Msg: PDBusMessage);
var
  iface, member: string;
begin
  if dbus_message_get_type(Msg) <> DBUS_MESSAGE_TYPE_METHOD_CALL then Exit;
  iface := SafeStr(dbus_message_get_interface(Msg));
  member := SafeStr(dbus_message_get_member(Msg));

  if iface = ImplInterface then
  begin
    if (member = 'OpenFile') or (member = 'SaveFile') or (member = 'SaveFiles') then
      HandlePick(Msg, member)
    else
      ReplyError(Msg, 'org.freedesktop.DBus.Error.UnknownMethod', member);
  end
  else if iface = 'org.freedesktop.DBus.Properties' then
  begin
    if member = 'GetAll' then
      ReplyEmptyDict(Msg)
    else
      ReplyError(Msg, 'org.freedesktop.DBus.Error.UnknownProperty', 'none');
  end
  else
    ReplyError(Msg, 'org.freedesktop.DBus.Error.UnknownMethod', iface + '.' + member);
end;

constructor TPortalService.Create(AHandler: TPickHandler);
var
  err: DBusError;
  r: cint;
begin
  FHandler := AHandler;
  dbus_error_init(@err);
  FConn := dbus_bus_get(DBUS_BUS_SESSION, @err);
  if FConn = nil then
    raise Exception.Create('cannot connect to session bus: ' + SafeStr(err.message));
  dbus_connection_set_exit_on_disconnect(FConn, 0);
  r := dbus_bus_request_name(FConn, BusName, DBUS_NAME_FLAG_DO_NOT_QUEUE, @err);
  if r <> DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER then
    raise Exception.Create('cannot own ' + BusName + ' (already running?)');
end;

function TPortalService.Poll: Boolean;
var
  msg: PDBusMessage;
begin
  Result := dbus_connection_read_write(FConn, 0) <> 0;
  msg := dbus_connection_pop_message(FConn);
  while msg <> nil do
  begin
    try
      HandleMessage(msg);
    finally
      dbus_message_unref(msg);
    end;
    msg := dbus_connection_pop_message(FConn);
  end;
end;

end.
