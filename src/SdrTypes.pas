unit SdrTypes;

{
  RTLSDR Scanner - Delphi 12 移植版
  基础类型 / 常量 / 通用数学函数

  对应原 Python 工程: constants.py, misc.py(部分)

  作者: 老皮
  QQ: 30922884
  主页: www.2pascal.com
  GitHub: github.com/shirong21cn
}

interface

uses
  System.SysUtils, System.Math;

const
  APP_NAME      = 'RTLSDR Scanner';
  APP_VER       = '2.0 (Delphi 12 port)';

  F_MIN         = 0;          // MHz
  F_MAX         = 9999;       // MHz
  SAMPLE_RATE   = 2000000.0;  // Hz, RTL-SDR 固定采样率
  BANDWIDTH     = 500000.0;   // Hz, 每步有效带宽
  LOCATION_PORT = 7786;

  DWELL_COUNT = 11;
  NFFT_COUNT  = 11;

type
  TScanMode    = (smSingle, smContinuous);
  TDisplayMode = (dmPlot, dmSpectrogram, dmSpectrogram3D, dmStatus,
                  dmTimeLine, dmPreview);
  TPlotFunc    = (pfNone, pfAvg, pfMin, pfMax, pfVar, pfSmooth, pfDiff);
  TWindowKind  = (wkBartlett, wkBlackman, wkHamming, wkHanning);

  { 扫描线程 -> 界面 的通知事件类型, 对应 events.py 的 Event }
  TScanEvent = (seStarting, seSteps, seInfo, seData, seStopped, seError,
                seFinished, seCal, seLevel, seUpdated);

  TPoint2D = record
    X: Double;   // 频率 MHz
    Y: Double;   // 电平 dB
  end;

  TPoint2DArray = TArray<TPoint2D>;

const
  DWELL_TEXT: array[0..DWELL_COUNT - 1] of string =
    ('8 ms', '16 ms', '32 ms', '65 ms', '131 ms', '262 ms', '524 ms',
     '1 s', '2 s', '4 s', '8 s');

  DWELL_VALUE: array[0..DWELL_COUNT - 1] of Double =
    (0.008, 0.016, 0.032, 0.065, 0.131, 0.262, 0.524, 1.048, 2.097, 4.194, 8.388);

  { 注意: 原程序 NFFT 列表中没有 256, 此处保持一致 }
  NFFT_VALUES: array[0..NFFT_COUNT - 1] of Integer =
    (16, 32, 64, 128, 512, 1024, 2048, 4096, 8192, 16384, 32768);

  WINDOW_NAME: array[TWindowKind] of string =
    ('Bartlett', 'Blackman', 'Hamming', 'Hanning');

  TUNER_NAME: array[0..6] of string =
    ('Unknown', 'Elonics E4000', 'Fitipower FC0012', 'Fitipower FC0013',
     'FCI FC2580', 'Rafael Micro R820T', 'Rafael Micro R828D');

  DISPLAY_TEXT: array[TDisplayMode] of string =
    ('Plot', 'Spectrogram', '3D Spectrogram', 'Status', 'Time Line', 'Preview');

function Next2ToPow(Val: Integer): Integer;
function CalcSamples(Dwell: Double): Integer;
function CalcRealDwell(Dwell: Double): Double;
function NearestIndex(Value: Double; const Values: array of Double): Integer;
function LimitInt(Value, Min, Max: Integer): Integer;
function LimitDouble(Value, Min, Max: Double): Double;
function LevelToDb(Level: Double): Double;
function DbToLevel(Db: Double): Double;
function WindowByName(const Name: string; out Kind: TWindowKind): Boolean;
function TunerName(Index: Integer): string;
function FormatFreq(FreqMHz, Precision: Double): string;
function FormatTime(TimeStamp: Double; WithDate: Boolean = False): string;
function IsoTime(TimeStamp: Double): string;

implementation

uses
  System.DateUtils;

function Next2ToPow(Val: Integer): Integer;
begin
  Result := 1;
  if Val < 1 then
    Exit;
  while Result < Val do
    Result := Result * 2;
end;

{ 对应 misc.calc_samples: 采样点数取整为 2 的幂 }
function CalcSamples(Dwell: Double): Integer;
begin
  Result := Next2ToPow(Trunc(Dwell * SAMPLE_RATE));
end;

function CalcRealDwell(Dwell: Double): Double;
begin
  Result := CalcSamples(Dwell) / SAMPLE_RATE;
  Result := Trunc(Result * 1000.0) / 1000.0;
end;

function NearestIndex(Value: Double; const Values: array of Double): Integer;
var
  I, Best: Integer;
  D, BestD: Double;
begin
  Result := 0;
  if Length(Values) = 0 then
    Exit;
  Best := 0;
  BestD := Abs(Value - Values[0]);
  for I := 1 to High(Values) do
  begin
    D := Abs(Value - Values[I]);
    if D < BestD then
    begin
      BestD := D;
      Best := I;
    end;
  end;
  Result := Best;
end;

function LimitInt(Value, Min, Max: Integer): Integer;
begin
  Result := Max;
  if Value < Max then
    Result := Value;
  if Result < Min then
    Result := Min;
end;

function LimitDouble(Value, Min, Max: Double): Double;
begin
  Result := Max;
  if Value < Max then
    Result := Value;
  if Result < Min then
    Result := Min;
end;

function LevelToDb(Level: Double): Double;
begin
  if Level <= 0 then
    Result := -200
  else
    Result := 10 * Log10(Level);
end;

function DbToLevel(Db: Double): Double;
begin
  Result := Power(10, Db / 10.0);
end;

function WindowByName(const Name: string; out Kind: TWindowKind): Boolean;
var
  K: TWindowKind;
begin
  Result := False;
  for K := Low(TWindowKind) to High(TWindowKind) do
    if SameText(WINDOW_NAME[K], Name) then
    begin
      Kind := K;
      Result := True;
      Exit;
    end;
  Kind := wkHamming;
end;

function TunerName(Index: Integer): string;
begin
  if (Index >= 0) and (Index <= High(TUNER_NAME)) then
    Result := TUNER_NAME[Index]
  else
    Result := TUNER_NAME[0];
end;

function FormatFreq(FreqMHz, Precision: Double): string;
var
  Fmt: string;
begin
  if Precision < 0 then
    Precision := 0;
  Fmt := '%.' + IntToStr(Trunc(Precision)) + 'f';
  Result := Format(Fmt, [FreqMHz]) + ' MHz';
end;

function FormatTime(TimeStamp: Double; WithDate: Boolean): string;
var
  DT: TDateTime;
begin
  DT := UnixToDateTime(Round(TimeStamp * 1000), False);
  if WithDate then
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', DT)
  else
    Result := FormatDateTime('hh:nn:ss', DT);
end;

function IsoTime(TimeStamp: Double): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz',
    UnixToDateTime(Round(TimeStamp * 1000), False));
end;

end.
