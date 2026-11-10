unit SdrSettings;

{
  配置持久化: 对应原工程 settings.py (wx.Config -> INI)

  存储位置: %APPDATA%\RTLSDRScanner\settings.ini
}

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.IOUtils,
  System.Generics.Collections, SdrTypes;

const
  { rtlsdr 设备序号保护上限(正常机器远小于此值, 仅防止异常索引撑爆设备列表) }
  MAX_RTL_INDEX = 63;

type
  TDeviceEntry = class
  public
    Name: string;
    Serial: string;
    Gain: Double;           // dB, 0 = 自动增益
    Calibration: Double;    // ppm
    Lo: Double;             // 下变频本振 MHz
    Offset: Double;         // 偏移 MHz
    Tuner: Integer;
    Selected: Boolean;
  end;

  TSdrSettings = class
  private
    FFileName: string;
    procedure EnsureDevice(Index: Integer);
  public
    StartMHz, StopMHz: Double;
    Mode: TScanMode;
    Dwell: Double;
    NFFT: Integer;
    Overlap: Double;
    WindowKind: TWindowKind;
    Display: TDisplayMode;
    IndexRtl: Integer;

    GainMode: Boolean;      // False = 自动增益
    Gain: Double;
    Calibration: Double;    // ppm
    Lo: Double;             // MHz
    Offset: Double;         // MHz

    MaxSweeps: Integer;     // 保留扫描条数(时间轴层数)
    AutoF, AutoL, AutoT: Boolean;

    BackgroundColour: Integer;
    LabelColour: Integer;
    TraceColour: Integer;
    PeakColour: Integer;
    YMin, YMax: Double;

    Devices: TObjectList<TDeviceEntry>;

    constructor Create;
    destructor Destroy; override;

    function ActiveDevice: TDeviceEntry;
    procedure NextScanRange(out RangeStart, RangeStop: Double);
    procedure Load;
    procedure Save;
    property FileName: string read FFileName;
    property Window: TWindowKind read WindowKind write WindowKind;
  end;

function DefaultSettingsDir: string;

implementation

type
  TScanRange = record
    StartMHz, StopMHz: Double;
  end;

function DefaultSettingsDir: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, 'RTLSDRScanner');
  if not TDirectory.Exists(Result) then
    TDirectory.CreateDirectory(Result);
end;

constructor TSdrSettings.Create;
begin
  inherited Create;
  Devices := TObjectList<TDeviceEntry>.Create(True);
  FFileName := TPath.Combine(DefaultSettingsDir, 'settings.ini');

  StartMHz := 87.5;
  StopMHz := 108.0;
  Mode := smSingle;
  Dwell := 0.131;
  NFFT := 1024;
  Overlap := 0.0;
  WindowKind := wkHamming;
  Display := dmPlot;
  IndexRtl := 0;

  GainMode := False;
  Gain := 0;
  Calibration := 0;
  Lo := 0;
  Offset := 0;

  MaxSweeps := 10;
  AutoF := True;
  AutoL := True;
  AutoT := True;

  BackgroundColour := $00202020;
  LabelColour := $00E0E0E0;
  TraceColour := $00C8F0C8;
  PeakColour := $006080FF;
  YMin := -100;
  YMax := 0;
end;

destructor TSdrSettings.Destroy;
begin
  Devices.Free;
  inherited;
end;

procedure TSdrSettings.EnsureDevice(Index: Integer);
var
  Dev: TDeviceEntry;
begin
  while Devices.Count <= Index do
  begin
    Dev := TDeviceEntry.Create;
    Dev.Name := '';
    Dev.Serial := '';
    Dev.Gain := 0;
    Dev.Calibration := 0;
    Dev.Lo := 0;
    Dev.Offset := 0;
    Dev.Tuner := 0;
    Dev.Selected := Devices.Count = 0;
    Devices.Add(Dev);
  end;
end;

function TSdrSettings.ActiveDevice: TDeviceEntry;
begin
  { IndexRtl 对本地 USB 设备直接就是 rtlsdr 的设备序号,
    不能按设备列表长度压缩(否则选中的第 3 个设备会被夹回 0),
    改为按需扩展列表条目 }
  IndexRtl := LimitInt(IndexRtl, 0, MAX_RTL_INDEX);
  EnsureDevice(IndexRtl);
  Result := Devices[IndexRtl];
end;

procedure TSdrSettings.NextScanRange(out RangeStart, RangeStop: Double);
begin
  { 单次扫描区间取自设置; 连续模式下由扫描线程按带宽循环滚动 }
  RangeStart := StartMHz;
  RangeStop := StopMHz;
end;

procedure TSdrSettings.Load;
var
  Ini: TIniFile;
  I, Count: Integer;
  Dev: TDeviceEntry;
  S: string;
begin
  if not FileExists(FFileName) then
    Exit;
  Ini := TIniFile.Create(FFileName);
  try
    StartMHz := Ini.ReadFloat('Frequency', 'Start', StartMHz);
    StopMHz := Ini.ReadFloat('Frequency', 'Stop', StopMHz);
    { 枚举值必须夹取到合法范围: 配置文件被改坏时避免越界访问 }
    Mode := TScanMode(LimitInt(Ini.ReadInteger('Scan', 'Mode', Ord(Mode)),
      Ord(Low(TScanMode)), Ord(High(TScanMode))));
    Dwell := Ini.ReadFloat('Scan', 'Dwell', Dwell);
    NFFT := Ini.ReadInteger('Scan', 'Nfft', NFFT);
    Overlap := Ini.ReadFloat('Scan', 'Overlap', Overlap);
    { 旧版本默认 0.25, 与原程序(matplotlib psd 默认 0)不一致, 迁移到 0 }
    if Abs(Overlap - 0.25) < 1.0E-9 then
      Overlap := 0.0;
    WindowKind := TWindowKind(LimitInt(Ini.ReadInteger('Scan', 'Window', Ord(WindowKind)),
      Ord(Low(TWindowKind)), Ord(High(TWindowKind))));
    Display := TDisplayMode(LimitInt(Ini.ReadInteger('Display', 'Type', Ord(Display)),
      Ord(Low(TDisplayMode)), Ord(High(TDisplayMode))));
    IndexRtl := Ini.ReadInteger('Device', 'Index', IndexRtl);

    GainMode := Ini.ReadBool('Gain', 'Manual', GainMode);
    Gain := Ini.ReadFloat('Gain', 'Value', Gain);
    Calibration := Ini.ReadFloat('Device', 'Calibration', Calibration);
    Lo := Ini.ReadFloat('Device', 'LO', Lo);
    Offset := Ini.ReadFloat('Device', 'Offset', Offset);

    MaxSweeps := Ini.ReadInteger('Plot', 'Sweeps', MaxSweeps);
    AutoF := Ini.ReadBool('Plot', 'AutoF', AutoF);
    AutoL := Ini.ReadBool('Plot', 'AutoL', AutoL);
    AutoT := Ini.ReadBool('Plot', 'AutoT', AutoT);
    BackgroundColour := Ini.ReadInteger('Plot', 'Background', BackgroundColour);
    LabelColour := Ini.ReadInteger('Plot', 'Labels', LabelColour);
    TraceColour := Ini.ReadInteger('Plot', 'Trace', TraceColour);
    PeakColour := Ini.ReadInteger('Plot', 'Peaks', PeakColour);
    YMin := Ini.ReadFloat('Plot', 'YMin', YMin);
    YMax := Ini.ReadFloat('Plot', 'YMax', YMax);

    { 兼容旧版配置: 电平下限默认值由 -80 调整为 -100 }
    if YMin = -80 then
      YMin := -100;

    Count := Ini.ReadInteger('Devices', 'Count', 0);
    for I := 0 to Count - 1 do
    begin
      EnsureDevice(I);
      Dev := Devices[I];
      S := 'Device' + IntToStr(I);
      Dev.Name := Ini.ReadString(S, 'Name', '');
      Dev.Serial := Ini.ReadString(S, 'Serial', '');
      Dev.Gain := Ini.ReadFloat(S, 'Gain', 0);
      Dev.Calibration := Ini.ReadFloat(S, 'Calibration', 0);
      Dev.Lo := Ini.ReadFloat(S, 'LO', 0);
      Dev.Offset := Ini.ReadFloat(S, 'Offset', 0);
      Dev.Tuner := Ini.ReadInteger(S, 'Tuner', 0);
      Dev.Selected := Ini.ReadBool(S, 'Selected', I = 0);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TSdrSettings.Save;
var
  Ini: TIniFile;
  I: Integer;
  Dev: TDeviceEntry;
  S: string;
begin
  Ini := TIniFile.Create(FFileName);
  try
    Ini.WriteFloat('Frequency', 'Start', StartMHz);
    Ini.WriteFloat('Frequency', 'Stop', StopMHz);
    Ini.WriteInteger('Scan', 'Mode', Ord(Mode));
    Ini.WriteFloat('Scan', 'Dwell', Dwell);
    Ini.WriteInteger('Scan', 'Nfft', NFFT);
    Ini.WriteFloat('Scan', 'Overlap', Overlap);
    Ini.WriteInteger('Scan', 'Window', Ord(WindowKind));
    Ini.WriteInteger('Display', 'Type', Ord(Display));
    Ini.WriteInteger('Device', 'Index', IndexRtl);

    Ini.WriteBool('Gain', 'Manual', GainMode);
    Ini.WriteFloat('Gain', 'Value', Gain);
    Ini.WriteFloat('Device', 'Calibration', Calibration);
    Ini.WriteFloat('Device', 'LO', Lo);
    Ini.WriteFloat('Device', 'Offset', Offset);

    Ini.WriteInteger('Plot', 'Sweeps', MaxSweeps);
    Ini.WriteBool('Plot', 'AutoF', AutoF);
    Ini.WriteBool('Plot', 'AutoL', AutoL);
    Ini.WriteBool('Plot', 'AutoT', AutoT);
    Ini.WriteInteger('Plot', 'Background', BackgroundColour);
    Ini.WriteInteger('Plot', 'Labels', LabelColour);
    Ini.WriteInteger('Plot', 'Trace', TraceColour);
    Ini.WriteInteger('Plot', 'Peaks', PeakColour);
    Ini.WriteFloat('Plot', 'YMin', YMin);
    Ini.WriteFloat('Plot', 'YMax', YMax);

    Ini.WriteInteger('Devices', 'Count', Devices.Count);
    for I := 0 to Devices.Count - 1 do
    begin
      Dev := Devices[I];
      S := 'Device' + IntToStr(I);
      Ini.WriteString(S, 'Name', Dev.Name);
      Ini.WriteString(S, 'Serial', Dev.Serial);
      Ini.WriteFloat(S, 'Gain', Dev.Gain);
      Ini.WriteFloat(S, 'Calibration', Dev.Calibration);
      Ini.WriteFloat(S, 'LO', Dev.Lo);
      Ini.WriteFloat(S, 'Offset', Dev.Offset);
      Ini.WriteInteger(S, 'Tuner', Dev.Tuner);
      Ini.WriteBool(S, 'Selected', Dev.Selected);
    end;
  finally
    Ini.Free;
  end;
end;

end.
