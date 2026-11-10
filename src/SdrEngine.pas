unit SdrEngine;

{
  扫描引擎: 对应原工程 scan.py 的 ThreadScan

  流程(与原程序一致):
    1. 频率从 (start - offset - BW) 起, 到 (stop + offset + 2*BW) 止, 步进 BW/2
    2. 每步设置中心频率 -> 同步读取 8bit IQ -> 解调为复数 -> Welch PSD
    3. PSD 相对频率叠加中心频率得到绝对频率, 按 [start, stop] 裁剪后回传界面
    4. 单次模式跑一遍即结束; 连续模式循环执行直到用户停止
}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils, System.SyncObjs,
  Winapi.Windows,
  SdrTypes, SdrDevice, SdrDsp, SdrSettings;

type
  TScanLogEvent = procedure(Sender: TObject; Ev: TScanEvent; const Msg: string) of object;
  TScanDataEvent = procedure(Sender: TObject; TimeStamp: Double;
    const Points: TPoint2DArray) of object;
  TScanProgressEvent = procedure(Sender: TObject; FreqHz: Int64;
    Step, TotalSteps: Integer) of object;

  TScanThread = class(TThread)
  private
    FSource: TRtlSource;
    FSettings: TSdrSettings;
    FStopEvent: TEvent;
    FOnLog: TScanLogEvent;
    FOnData: TScanDataEvent;
    FOnProgress: TScanProgressEvent;
    FTotalSteps: Integer;
    FSamples: Integer;
    procedure PostLog(Ev: TScanEvent; const Msg: string);
    procedure PostData(TimeStamp: Double; const Points: TPoint2DArray);
    procedure PostProgress(FreqHz: Int64; Step, TotalSteps: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(ASource: TRtlSource; ASettings: TSdrSettings);
    destructor Destroy; override;
    procedure StopScan;
    property OnLog: TScanLogEvent read FOnLog write FOnLog;
    property OnData: TScanDataEvent read FOnData write FOnData;
    property OnProgress: TScanProgressEvent read FOnProgress write FOnProgress;
    property TotalSteps: Integer read FTotalSteps;
    property Samples: Integer read FSamples;
  end;

function NowUnix: Double;

implementation

type
  TScanMsg = class
  public
    Kind: TScanEvent;
    Msg: string;
    TimeStamp: Double;
    FreqHz: Int64;
    Step: Integer;
    TotalSteps: Integer;
    Points: TPoint2DArray;
  end;

function NowUnix: Double;
begin
  Result := (TTimeZone.Local.ToUniversalTime(Now) - EncodeDate(1970, 1, 1)) * SecsPerDay;
end;

constructor TScanThread.Create(ASource: TRtlSource; ASettings: TSdrSettings);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSource := ASource;
  FSettings := ASettings;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FTotalSteps := 0;
  FSamples := CalcSamples(ASettings.Dwell);
end;

destructor TScanThread.Destroy;
begin
  FStopEvent.Free;
  inherited;
end;

procedure TScanThread.StopScan;
begin
  FStopEvent.SetEvent;
  Terminate;
end;

procedure TScanThread.PostLog(Ev: TScanEvent; const Msg: string);
var
  Item: TScanMsg;
begin
  if not Assigned(FOnLog) then
    Exit;
  Item := TScanMsg.Create;
  Item.Kind := Ev;
  Item.Msg := Msg;
  TThread.Queue(nil,
    procedure
    begin
      try
        if Assigned(FOnLog) then
          FOnLog(Self, Item.Kind, Item.Msg);
      finally
        Item.Free;
      end;
    end);
end;

procedure TScanThread.PostData(TimeStamp: Double; const Points: TPoint2DArray);
var
  Item: TScanMsg;
begin
  if not Assigned(FOnData) then
    Exit;
  Item := TScanMsg.Create;
  Item.TimeStamp := TimeStamp;
  Item.Points := Copy(Points);
  TThread.Queue(nil,
    procedure
    begin
      try
        if Assigned(FOnData) then
          FOnData(Self, Item.TimeStamp, Item.Points);
      finally
        Item.Free;
      end;
    end);
end;

procedure TScanThread.PostProgress(FreqHz: Int64; Step, TotalSteps: Integer);
var
  Item: TScanMsg;
begin
  if not Assigned(FOnProgress) then
    Exit;
  Item := TScanMsg.Create;
  Item.FreqHz := FreqHz;
  Item.Step := Step;
  Item.TotalSteps := TotalSteps;
  TThread.Queue(nil,
    procedure
    begin
      try
        if Assigned(FOnProgress) then
          FOnProgress(Self, Item.FreqHz, Item.Step, Item.TotalSteps);
      finally
        Item.Free;
      end;
    end);
end;

procedure TScanThread.Execute;
var
  Raw: TBytes;
  Re, Im, RelFreq, Power: TArray<Double>;
  Points: TPoint2DArray;
  StepHz, FreqHz, FreqStart, FreqStop, AbsMHz, Cal: Double;
  Stamp: Double;
  Step, Total, I, Count, BytesRead, Chunk, Samples, Retries: Integer;
  Aborted: Boolean;
  LastProgTick: Cardinal;
  LevelDb: Double;
begin
  try
    Aborted := False;
    LastProgTick := GetTickCount - 1000;
    Samples := CalcSamples(FSettings.Dwell);
    FSamples := Samples;
    SetLength(Raw, Samples * 2);

    if not FSource.IsOpen then
    begin
      PostLog(seError, '设备未打开');
      Exit;
    end;

    { 设备层可能缺少部分可选导出(旧版 rtlsdr.dll): 先告知用户, 避免扫描静默失败 }
    if (FSource is TRtlDevice) and (TRtlDevice(FSource).Lib.MissingCount > 0) then
      PostLog(seInfo, Format('当前 rtlsdr.dll 缺少 %d 个可选函数(%s), 相关设置将跳过',
        [TRtlDevice(FSource).Lib.MissingCount, TRtlDevice(FSource).Lib.MissingExports]));

    if not FSource.SetSampleRate(Round(SAMPLE_RATE)) then
      PostLog(seInfo, Format('设置采样率 %.0f Hz 失败, 使用设备当前值', [SAMPLE_RATE]));
    if not FSource.SetGainMode(FSettings.GainMode) then
      PostLog(seInfo, '设置增益模式失败, 使用设备默认模式');
    if FSettings.GainMode and not FSource.SetGain(Round(FSettings.Gain * 10)) then
      PostLog(seInfo, '设置增益值失败, 使用设备当前增益');

    Cal := 1 + FSettings.Calibration / 1.0E6;
    StepHz := BANDWIDTH / 2;
    FreqStart := FSettings.StartMHz * 1.0E6 - FSettings.Offset * 1.0E6 - BANDWIDTH;
    FreqStop := FSettings.StopMHz * 1.0E6 + FSettings.Offset * 1.0E6 + 2 * BANDWIDTH;
    Total := Trunc((FreqStop - FreqStart) / StepHz) + 1;
    FTotalSteps := Total;

    PostLog(seStarting, Format('开始扫描 %.3f - %.3f MHz, 步进 %.1f kHz, 每步 %d 点',
      [FSettings.StartMHz, FSettings.StopMHz, StepHz / 1000, Samples]));

    repeat
      Stamp := NowUnix;
      Step := 0;
      FreqHz := FreqStart;

      while (not Terminated) and (FreqHz <= FreqStop) do
      begin
        if FStopEvent.WaitFor(0) = wrSignaled then
          Break;

        FSource.SetCenterFreq(Round(FreqHz + FSettings.Lo * 1.0E6));

        BytesRead := 0;
        Retries := 0;
        { 分块累加读取: 设备可能只返回部分数据, 必须写到缓冲区剩余位置,
          否则每次短读都会从头覆盖, 既丢数据又可能永远凑不满而空转 }
        while (BytesRead < Length(Raw)) and (Retries < 3) and (not Terminated) do
        begin
          Chunk := 0;
          if FSource.ReadSamples(@Raw[BytesRead], Length(Raw) - BytesRead, Chunk)
             and (Chunk > 0) then
            Inc(BytesRead, Chunk)
          else
          begin
            Inc(Retries);
            Sleep(20);
          end;
        end;

        if BytesRead <= 0 then
        begin
          PostLog(seError, Format('在 %.3f MHz 采数失败', [FreqHz / 1.0E6]));
          Aborted := True;
          Break;
        end;

        RawToIQ(@Raw[0], BytesRead div 2, Re, Im);
        ComputePSD(Re, Im, FSettings.NFFT, FSettings.Overlap, FSettings.WindowKind,
          SAMPLE_RATE, RelFreq, Power);

        Count := 0;
        SetLength(Points, Length(RelFreq));
        for I := 0 to High(RelFreq) do
        begin
          AbsMHz := ((FreqHz + RelFreq[I] * 1.0E6) / 1.0E6) * Cal;
          if (AbsMHz < FSettings.StartMHz - 0.001) or
             (AbsMHz > FSettings.StopMHz + 0.001) then
            Continue;
          LevelDb := LevelToDb(Power[I]);
          Points[Count].X := AbsMHz;
          Points[Count].Y := LevelDb;
          Inc(Count);
        end;
        SetLength(Points, Count);

        if Count > 0 then
          PostData(Stamp, Points);

        Inc(Step);
        { 进度条无需每步刷新: 大跨度时每步入队会压垮消息泵, 按 100ms 节流 }
        if (Step >= Total) or (GetTickCount - LastProgTick >= 100) then
        begin
          LastProgTick := GetTickCount;
          PostProgress(Round(FreqHz), Step, Total);
        end;
        FreqHz := FreqHz + StepHz;
      end;

      if Aborted or Terminated or (FStopEvent.WaitFor(0) = wrSignaled) then
        Break;

      if FSettings.Mode = smSingle then
        Break;

      PostLog(seInfo, '一次完整扫描结束, 继续下一轮');
    until Aborted or Terminated or (FStopEvent.WaitFor(0) = wrSignaled);

  except
    on E: Exception do
      PostLog(seError, E.Message);
  end;

  PostLog(seFinished, '扫描已停止');
end;

end.
