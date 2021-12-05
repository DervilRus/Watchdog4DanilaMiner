unit UnitHelper;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  System.IOUtils,
  System.Classes,
  Winapi.Windows,
  System.Threading,
  System.DateUtils,
  System.SyncObjs,
  System.Net.HttpClient,
  TLHelp32,
  System.JSON,
  Unit1StatisticThread;

const
  ConstRotateFileMask = 'yyyy.mm.dd';
  ConstHashrateListCount = 50;

type

  TParsedValue = (None, HashrateAverage, HashFoundCount);
  TRestartTag = record
    Tag : String;
    RepeatCount : Integer;
    RepeatCountMax : Integer;
  end;
  TRestartTags = TArray<TRestartTag>;


  THashrateList = TList<Double>;
  TSettings = record
    MinerFilePath : String;
    WalletAddress : String;
    PoolID : Integer;
    PoolUrls : TArray<String>;
    MinerParams : String;
    RestartTags : TRestartTags;
    PoolChangeTags : TArray<String>;
    Hashrate : Double;
    HashrateAverage : Double;
    HashrateList : THashrateList;
    ShareCount : Int64;
    RigName : String;
    LogFileName : String;
    ConsoleReadTimeoutSec : Integer;
  end;

  function ConfigLoad(out AConfigFilePath : String) : Boolean;
  procedure StartMiner(CommandLine : String; AWorkDir : String);
  procedure StopMiner();
  procedure LogConsole(const AMessage : String);
  procedure LogConsoleWatchdog(const AMessage : String);
  function Handler(dwCtrlType: DWORD): Boolean; stdcall;
  function GetBuildInfoAsString : string;
  procedure StartGetBalanceThread(const AWalletAddress : String);
  function GetBalance() : String;

var
  FSettings : TSettings;
  FProcessInformation: TProcessInformation;
  FFormatSettings : TFormatSettings;
  FQuele : TThreadedQueue<String>;
  FQueleBalance : TThreadedQueue<Double>;
  FTask : ITask;
  FTaskBalance : ITask;
  FBalance : Double;
  FStatisticThread : TStatisticThread;
  FQueueStatistic : TThreadedQueue<TStatistic>;

implementation


function StrOemToString(const aStr : AnsiString; const ALength : Integer) : String;
var AAnsiString : AnsiString;
begin
  SetLength(AAnsiString, ALength);
  OemToCharBuffA(PAnsiChar(aStr), PAnsiChar(AAnsiString), ALength);
  Result := String(AAnsiString);
end;

function CheckTags(AContent : String) : boolean;
var I : Integer;
    ARestartTag : Boolean;
begin
  Result := False;
  ARestartTag := False;
  AContent := AContent.ToLower;
  for I := Low(FSettings.RestartTags) to High(FSettings.RestartTags) do
    if AContent.Contains(FSettings.RestartTags[I].Tag) then
    begin
      ARestartTag := True;
      Inc(FSettings.RestartTags[I].RepeatCount);
      if FSettings.RestartTags[I].RepeatCount >= FSettings.RestartTags[I].RepeatCountMax then
      begin
        FSettings.RestartTags[I].RepeatCount := 0;
        Result := True;
      end;
      break;
    end;
  if not ARestartTag then
    for I := Low(FSettings.RestartTags) to High(FSettings.RestartTags) do
      FSettings.RestartTags[I].RepeatCount := 0;

  for I := Low(FSettings.PoolChangeTags) to High(FSettings.PoolChangeTags) do
    if AContent.Contains(FSettings.PoolChangeTags[I]) then
    begin
      Result := True;
      if FSettings.PoolID = High(FSettings.PoolUrls)  then
        FSettings.PoolID := 0
      else
        Inc(FSettings.PoolID);
      LogConsole('Watchdog: change pool to ' + FSettings.PoolUrls[FSettings.PoolID]);
      break;
    end;

end;

procedure ParseOutput(const AContent : String; out AParsedValue : TParsedValue);
const
  ConstTotalSystemHashrateMask = 'Total system hashrate';
  ConstHashFoundMask = 'FOUND';
var ATempStr : String;
    ATempDouble : Double;
    I : Integer;
begin
  AParsedValue := TParsedValue.None;
  if AContent.Contains(ConstTotalSystemHashrateMask) then
  begin
    ATempStr := AContent.Substring(AContent.IndexOf(ConstTotalSystemHashrateMask) + ConstTotalSystemHashrateMask.Length + 1);
    ATempStr := ATempStr.Substring(0, ATempStr.IndexOf(' '));
    ATempStr := ATempStr.Replace('.', FFormatSettings.DecimalSeparator);
    ATempStr := ATempStr.Replace(',', FFormatSettings.DecimalSeparator);
    if TryStrToFloat(ATempStr, ATempDouble) then
    begin
      FSettings.Hashrate := ATempDouble;

      if ATempDouble <> 0 then
      begin
        FSettings.HashrateList.Add(ATempDouble);
        while FSettings.HashrateList.Count > ConstHashrateListCount do
          FSettings.HashrateList.Delete(0);
        ATempDouble := 0;
        for I := 0 to FSettings.HashrateList.Count - 1 do
          ATempDouble := ATempDouble + FSettings.HashrateList.Items[I];
      end;
      FSettings.HashrateAverage := ATempDouble / FSettings.HashrateList.Count;
      AParsedValue := TParsedValue.HashrateAverage;
    end;
  end;
  if AContent.Contains(ConstHashFoundMask) then
  begin
    Inc(FSettings.ShareCount);
    AParsedValue := TParsedValue.HashFoundCount;
  end;
end;

procedure StartMiner(CommandLine : String; AWorkDir : String);
const ConstBufferLength = 1024;
var
  ASecurityAttributes : TSecurityAttributes;
  AStartupInfo : TStartupInfo;
  StdOutPipeRead, StdOutPipeWrite : THandle;
  WorkDir : string;
  Handle : Boolean;
  AOutputLine : String;
  AStopCounter : Integer;
  AParsedValue : TParsedValue;
  ATimeLastRead : TDateTime;
  AReadTimeoutSec : Int64;
  FStatistic : TStatistic;
begin
  LogConsoleWatchdog('Start ' + TPath.GetFileName(FSettings.MinerFilePath) + ' use pool ' + FSettings.PoolUrls[FSettings.PoolID]);
  FSettings.HashrateList.Clear;
  while FQuele.PopItem(AOutputLine) = TWaitResult.wrSignaled do ;
  AOutputLine := '';
  with ASecurityAttributes do begin
    nLength := SizeOf(ASecurityAttributes);
    bInheritHandle := True;
    lpSecurityDescriptor := nil;
  end;
  CreatePipe(StdOutPipeRead, StdOutPipeWrite, @ASecurityAttributes, 0);
  try
    with AStartupInfo do
    begin
      FillChar(AStartupInfo, SizeOf(AStartupInfo), 0);
      cb := SizeOf(AStartupInfo);
      dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES or SW_HIDE;
      hStdInput := GetStdHandle(STD_INPUT_HANDLE);
      hStdOutput := StdOutPipeWrite;
      hStdError := StdOutPipeWrite;
    end;
    WorkDir := AWorkDir;
    AOutputLine := '';
    Handle := CreateProcess(
      Nil,
      PChar(CommandLine),
      nil,
      nil,
      True,
      NORMAL_PRIORITY_CLASS,
      nil,
      PChar(WorkDir),
      AStartupInfo,
      FProcessInformation);
    CloseHandle(StdOutPipeWrite);
    AStopCounter := -1;
    if Handle then
    begin

      FTask := TTask.Run(
        procedure
        var AAQuele : TThreadedQueue<String>;
            AAWasReadOK : Boolean;
            AAOutputLine : String;
            AABytesRead : Cardinal;
            AAStdOutPipeRead : THandle;
            AABuffer : array[0..ConstBufferLength] of AnsiChar;
        begin
          AAQuele := FQuele;
          AAStdOutPipeRead := StdOutPipeRead;
          repeat
            try
              AAWasReadOK := ReadFile(AAStdOutPipeRead, AABuffer, ConstBufferLength, AABytesRead, nil);
              if (AABytesRead > 0) and AAWasReadOK then
              begin
                AABuffer[AABytesRead] := #0;
                AAOutputLine := StrOemToString(AABuffer, AABytesRead);
                AAQuele.PushItem(AAOutputLine);
              end;
            except
              break;
            end;
          until FTask.Status = TTaskStatus.Canceled;
        end
      );

      try
        ATimeLastRead := Now();
        repeat
          if FQuele.PopItem(AOutputLine) = TWaitResult.wrSignaled then
          begin
            ATimeLastRead := Now();

            ParseOutput(AOutputLine, AParsedValue);

            AOutputLine := AOutputLine.Trim;
            case AParsedValue of
              TParsedValue.HashrateAverage :
              begin
                with FStatistic do
                begin
                  Address := FSettings.WalletAddress;
                  RigName := FSettings.RigName;
                  Hashrate := FSettings.Hashrate;
                  HashrateAverage := FSettings.HashrateAverage;
                  ShareCount := FSettings.ShareCount;
                end;
                FQueueStatistic.PushItem(FStatistic);

                AOutputLine := AOutputLine + ' | Watchdog: Average hashrate ' + FSettings.HashrateAverage.ToString(TFloatFormat.ffFixed, 15, 2) + ' Mhash/s' + ' | ' + GetBalance();
              end;
              TParsedValue.HashFoundCount :
                AOutputLine := AOutputLine + ' | Watchdog: All found count ' + FSettings.ShareCount.ToString;
            end;

            LogConsole(AOutputLine.Trim);

            if CheckTags(AOutputLine) and (AStopCounter = -1) then
              AStopCounter := 2;
            if AStopCounter > 0 then
              Dec(AStopCounter);
            if AStopCounter = 0  then
            begin
              StopMiner();
              Exit;
            end;
          end;
          AReadTimeoutSec := SecondsBetween(ATimeLastRead, Now());
          if AReadTimeoutSec > FSettings.ConsoleReadTimeoutSec then
          begin
            LogConsoleWatchdog('Miner output read timeout ' + AReadTimeoutSec.ToString + ' sec');
            break;
          end;
        until (FTask.Status = TTaskStatus.Canceled);
        StopMiner();
        WaitForSingleObject(FProcessInformation.hProcess, INFINITE);
      finally
        CloseHandle(FProcessInformation.hThread);
        CloseHandle(FProcessInformation.hProcess);
      end;
    end;
  finally
    CloseHandle(StdOutPipeRead);
    if Assigned(FTask) then
      FTask.Cancel;
  end;
end;

function KillTask(ExeFileName: string): Integer;
const
  PROCESS_TERMINATE = $0001;
var
  ContinueLoop: BOOL;
  FSnapshotHandle: THandle;
  FProcessEntry32: TProcessEntry32;
begin
  Result := 0;
  FSnapshotHandle := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  FProcessEntry32.dwSize := SizeOf(FProcessEntry32);
  ContinueLoop := Process32First(FSnapshotHandle, FProcessEntry32);

  while Integer(ContinueLoop) <> 0 do
  begin
    if ((UpperCase(ExtractFileName(FProcessEntry32.szExeFile)) =
      UpperCase(ExeFileName)) or (UpperCase(FProcessEntry32.szExeFile) =
      UpperCase(ExeFileName))) then
      Result := Integer(TerminateProcess(
                        OpenProcess(PROCESS_TERMINATE,
                                    BOOL(0),
                                    FProcessEntry32.th32ProcessID),
                                    0));
     ContinueLoop := Process32Next(FSnapshotHandle, FProcessEntry32);
  end;
  CloseHandle(FSnapshotHandle);
end;

function GetProcessList(out AProcessList : TList<TProcessEntry32>) : Boolean;
var hSnapshoot: THandle;
    pe32: TProcessEntry32;
begin
  Result := False;
  AProcessList := TList<TProcessEntry32>.Create;

  hSnapshoot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);

  if hSnapshoot = INVALID_HANDLE_VALUE then
    Exit;
  pe32.dwSize := SizeOf(TProcessEntry32);
  if (Process32First(hSnapshoot, pe32)) then
    Repeat
      if (pe32.th32ProcessID = FProcessInformation.dwProcessId) or (pe32.th32ParentProcessID = FProcessInformation.dwProcessId) then
      begin
        AProcessList.Add(pe32);
        Result := True;
      end;
    Until not Process32Next(hSnapshoot, pe32);
  CloseHandle (hSnapshoot);
end;

procedure StopMiner();
var AProcessList : TList<TProcessEntry32>;
    I : Integer;
begin
  if GetProcessList(AProcessList) then
    for I := 0 to AProcessList.Count - 1 do
      TerminateProcess(
        OpenProcess(
          PROCESS_TERMINATE,
          BOOL(0),
          AProcessList[I].th32ProcessID
        ),
        0
      );
end;

function ConfigLoad(out AConfigFilePath : String) : Boolean;
var AConfigContent : String;
    AJSON : TJSONObject;
    I : Integer;
    AStringArray : TArray<String>;
begin
  Result := False;

  if ParamCount > 0 then
    AConfigFilePath := ParamStr(1)
  else
    AConfigFilePath := TPath.ChangeExtension(ParamStr(0), '.json');


  if Not TFile.Exists(AConfigFilePath) then
  begin
    LogConsole('ERROR Config file not found ' + AConfigFilePath);
    exit;
  end;

  try
    AConfigContent := TFile.ReadAllText(AConfigFilePath, TEncoding.UTF8);
  except
    LogConsole('ERROR Config file read ' + AConfigFilePath);
    exit;
  end;

  if AConfigContent.Trim.IsEmpty then
  begin
    LogConsole('ERROR Config file is empty ' + AConfigFilePath);
    exit;
  end;
  AConfigContent := AConfigContent.Replace('\', '\\', [rfReplaceAll]);

  try
    AJSON := TJSONObject(TJSONObject.ParseJSONValue(AConfigContent));
    if Not Assigned(AJSON) then
    begin
      LogConsole('ERROR Config file parse ' + AConfigFilePath);
      exit;
    end;

    if not AJSON.TryGetValue('MinerFilePath', FSettings.MinerFilePath) then
    begin
      LogConsole('ERROR read value MinerFilePath');
      exit;
    end;

    if not AJSON.TryGetValue('WalletAddress', FSettings.WalletAddress) then
    begin
      LogConsole('ERROR read value WalletAddress');
      exit;
    end;

    if not AJSON.TryGetValue('RigName', FSettings.RigName) then
    begin
      LogConsole('ERROR read value RigName');
      FSettings.RigName := 'noname';
    end;
    FSettings.RigName := FSettings.RigName.Substring(0, 17);

    if not AJSON.TryGetValue('LogFileName', FSettings.LogFileName) then
    begin
      LogConsole('ERROR read value LogFileName');
      exit;
    end;

    if not AJSON.TryGetValue('ConsoleReadTimeoutSec', FSettings.ConsoleReadTimeoutSec) then
    begin
      LogConsole('ERROR read value ConsoleReadTimeoutSec');
      FSettings.ConsoleReadTimeoutSec := 40;
    end;

    if not AJSON.TryGetValue('MinerParams', FSettings.MinerParams) then
    begin
      LogConsole('ERROR read value MinerParams');
      exit;
    end;

    if not AJSON.TryGetValue('PoolUrls', FSettings.PoolUrls) then
    begin
      LogConsole('ERROR read value PoolUrls');
      exit;
    end;

    if not AJSON.TryGetValue('RestartTags', AStringArray) then
    begin
      LogConsole('ERROR read value RestartTags');
      exit;
    end;

    if not AJSON.TryGetValue('PoolChangeTags', FSettings.PoolChangeTags) then
    begin
      LogConsole('ERROR read value PoolChangeTags');
      exit;
    end;

    SetLength(FSettings.RestartTags, Length(AStringArray));
    for I := Low(AStringArray) to High(AStringArray) do
    begin
      FSettings.RestartTags[I].Tag := AStringArray[I].ToLower;
      FSettings.RestartTags[I].RepeatCount := 0;
      if AStringArray[I].ToLower.Equals('hashrate 0.0') then
        FSettings.RestartTags[I].RepeatCountMax := 4
      else
        FSettings.RestartTags[I].RepeatCountMax := 1;
    end;

    for I := Low(FSettings.PoolChangeTags) to High(FSettings.PoolChangeTags) do
      FSettings.PoolChangeTags[I] := FSettings.PoolChangeTags[I].ToLower;
    FSettings.PoolID := 0;

  finally
    FreeAndNil(AJSON);
  end;
  Result := True;
end;

procedure LogConsole(const AMessage : String);
var ALogPath : String;
    LMessage : String;
begin
  try
    LMessage := AMessage.Trim;
  except
  end;
  Writeln(LMessage);

  if FSettings.LogFileName.IsEmpty then
    FSettings.LogFileName := TPath.ChangeExtension(ParamStr(0), '.log');

  if TPath.GetDirectoryName(FSettings.LogFileName) = '' then
    ALogPath := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), FSettings.LogFileName)
  else
    ALogPath := FSettings.LogFileName;
  if TPath.GetExtension(ALogPath) = '' then
    ALogPath := ALogPath + '.log';

  ALogPath :=
    IncludeTrailingPathDelimiter( TPath.GetDirectoryName(ALogPath)) +
    TPath.GetFileNameWithoutExtension(ALogPath) +
    '_' +
    FormatDateTime(ConstRotateFileMask, Now()) +
    TPath.GetExtension(ALogPath);

  try
    TFile.AppendAllText(ALogPath, LMessage + #10, TEncoding.UTF8);
  except
  end;
end;

procedure LogConsoleWatchdog(const AMessage : String);
var ADateTimeString : String;
    LMessage : String;
begin
  try
    LMessage := AMessage.Trim;
  except
  end;
  ADateTimeString := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now());
  LogConsole(ADateTimeString + ' ' + StringOfChar('*', LMessage.Length + 2));
  LogConsole(ADateTimeString + '  ' + LMessage);
  LogConsole(ADateTimeString + ' ' + StringOfChar('*', LMessage.Length + 2));
end;

function Handler(dwCtrlType: DWORD): Boolean; stdcall;
begin
  Result := False;
  case dwCtrlType of
    CTRL_C_EVENT, CTRL_BREAK_EVENT :
    begin
      StopMiner();
      Halt;
      Result := True;
    end;
    CTRL_CLOSE_EVENT :
    begin
      StopMiner();
      Result := True;
    end;
  end;
end;


procedure GetBuildInfo(var V1, V2, V3, V4: word);
var
  VerInfoSize, VerValueSize, Dummy: DWORD;
  VerInfo: Pointer;
  VerValue: PVSFixedFileInfo;
begin
  VerInfoSize := GetFileVersionInfoSize(PChar(ParamStr(0)), Dummy);
  if VerInfoSize > 0 then
  begin
      GetMem(VerInfo, VerInfoSize);
      try
        if GetFileVersionInfo(PChar(ParamStr(0)), 0, VerInfoSize, VerInfo) then
        begin
          VerQueryValue(VerInfo, '\', Pointer(VerValue), VerValueSize);
          with VerValue^ do
          begin
            V1 := dwFileVersionMS shr 16;
            V2 := dwFileVersionMS and $FFFF;
            V3 := dwFileVersionLS shr 16;
            V4 := dwFileVersionLS and $FFFF;
          end;
        end;
      finally
        FreeMem(VerInfo, VerInfoSize);
      end;
  end;
end;

function GetBuildInfoAsString : string;
var
  V1, V2, V3, V4: word;
begin
  GetBuildInfo(V1, V2, V3, V4);
  Result := 'Watchdog for Danila miner ' +
    IntToStr(V1) + '.' + IntToStr(V2) + '.' +
    IntToStr(V3) + '.' + IntToStr(V4);
end;


procedure StartGetBalanceThread(const AWalletAddress : String);
begin
    FTaskBalance := TTask.Run(
        procedure
        var AQuery : String;
            AQueleBalance : TThreadedQueue<Double>;
            AHTTPClient : THTTPClient;
            AHTTPResponse : IHTTPResponse;
            AJSON : TJSONObject;
            ABalance : Double;
        begin
          AQuery := 'https://server1.whalestonpool.com/wallet/' + AWalletAddress;
          AQueleBalance := FQueleBalance;
          AHTTPClient := THTTPClient.Create;
          try
          repeat
            try
              AHTTPResponse := AHTTPClient.Get(AQuery);
              if Assigned(AHTTPResponse) then
                if AHTTPResponse.StatusCode = 200 then
                try
                  AJSON := TJSONObject.ParseJSONValue(AHTTPResponse.ContentAsString()) as TJSONObject;
                  if Assigned(AJSON) then
                    if AJSON.TryGetValue('balance', ABalance) then
                      AQueleBalance.PushItem(ABalance / 1000000000);
                finally
                  FreeAndNil(AJSON);
                end;
              TThread.Sleep(30000);
            except
            end;
          until FTaskBalance.Status = TTaskStatus.Canceled;
          finally
            FreeAndNil(AHTTPClient);
          end;
        end
      );
end;

function GetBalance() : String;
var ABalance : Double;
    ABalanceDelta : Double;
    ABalanceDeltaText : String;
begin
  ABalance := 0;
  Result := 'Balance ';
  ABalanceDeltaText := '';
  if FQueleBalance.PopItem(ABalance) = TWaitResult.wrSignaled then
  begin
    if (FBalance <> 0) and (FBalance <> ABalance) then
    begin
      ABalanceDelta := ABalance - FBalance;
      ABalanceDeltaText := ' (';
      if ABalanceDelta > 0 then
        ABalanceDeltaText := ABalanceDeltaText + '+';
      ABalanceDeltaText := ABalanceDeltaText + ABalanceDelta.ToString(TFloatFormat.ffFixed, 15, 8) + ')';
    end;
    FBalance := ABalance;
  end;
  Result := Result + FBalance.ToString(TFloatFormat.ffFixed, 15, 8) + ABalanceDeltaText;
end;

initialization

finalization

end.
