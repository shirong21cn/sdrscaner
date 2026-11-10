unit SdrDevice;

{
  设备层: 对应原工程 devices.py + rtltcp.py + pyrtlsdr 绑定

  1) TRtlSdrLib     : rtlsdr.dll 动态绑定 (rtl-sdr 官方 C API)
  2) TRtlDevice     : 本地 USB 设备 (R820T / E4000 ...)
}

interface

uses
  System.SysUtils, System.Classes, System.Math, Winapi.Windows, SdrTypes;

const
  RTLSDR_TUNER_UNKNOWN = 0;
  RTLSDR_TUNER_E4000   = 1;
  RTLSDR_TUNER_FC0012  = 2;
  RTLSDR_TUNER_FC0013  = 3;
  RTLSDR_TUNER_FC2580  = 4;
  RTLSDR_TUNER_R820T   = 5;
  RTLSDR_TUNER_R828D   = 6;

type
  TDeviceInfo = record
    Index: Integer;
    Name: string;
    Manufacturer: string;
    Serial: string;
  end;
  TDeviceInfoArray = TArray<TDeviceInfo>;

  { 设备抽象: 本地/远程统一接口 }
  TRtlSource = class
  public
    function SetSampleRate(Rate: Cardinal): Boolean; virtual; abstract;
    function SetCenterFreq(FreqHz: Cardinal): Boolean; virtual; abstract;
    function SetGainMode(Manual: Boolean): Boolean; virtual; abstract;
    function SetGain(GainTenthDb: Integer): Boolean; virtual; abstract;
    function ReadSamples(Buf: Pointer; ByteCount: Integer;
      out BytesRead: Integer): Boolean; virtual; abstract;
    function GetTunerType: Integer; virtual; abstract;
    function GetTunerGains: TArray<Double>; virtual; abstract;
    procedure Close; virtual; abstract;
    function IsOpen: Boolean; virtual; abstract;
  end;

  { ---- rtlsdr.dll 动态绑定 ---- }
  TRtlSdrLib = class
  private
    FLib: THandle;
    FDllPath: string;
    FMissing: string;
    FMissingCount: Integer;
  public
    rtlsdr_open: function(var Dev: Pointer; Index: Cardinal): LongInt; cdecl;
    rtlsdr_close: function(Dev: Pointer): LongInt; cdecl;
    rtlsdr_set_sample_rate: function(Dev: Pointer; Rate: Cardinal): LongInt; cdecl;
    rtlsdr_get_sample_rate: function(Dev: Pointer): Cardinal; cdecl;
    rtlsdr_set_center_freq: function(Dev: Pointer; Freq: Cardinal): LongInt; cdecl;
    rtlsdr_get_center_freq: function(Dev: Pointer): Cardinal; cdecl;
    rtlsdr_set_gain_mode: function(Dev: Pointer; Manual: LongInt): LongInt; cdecl;
    rtlsdr_set_tuner_gain: function(Dev: Pointer; Gain: LongInt): LongInt; cdecl;
    rtlsdr_get_tuner_gain: function(Dev: Pointer): LongInt; cdecl;
    rtlsdr_get_tuner_gains: function(Dev: Pointer; Gains: PLongInt): LongInt; cdecl;
    rtlsdr_get_tuner_type: function(Dev: Pointer): LongInt; cdecl;
    rtlsdr_reset_buffer: function(Dev: Pointer): LongInt; cdecl;
    rtlsdr_read_sync: function(Dev: Pointer; Buf: Pointer; Len: LongInt;
      NRead: PLongInt): LongInt; cdecl;
    rtlsdr_get_device_count: function: Cardinal; cdecl;
    rtlsdr_get_device_name: function(Index: Cardinal): PAnsiChar; cdecl;
    rtlsdr_get_device_usb_strings: function(Index: Cardinal;
      Manufact, Product, Serial: PAnsiChar): LongInt; cdecl;
    rtlsdr_set_tuner_bandwidth: function(Dev: Pointer; BW: Cardinal): LongInt; cdecl;

    constructor Create;
    destructor Destroy; override;
    function Load(const ADllPath: string; out Err: string): Boolean;
    function Loaded: Boolean;
    property DllPath: string read FDllPath;
    { 缺失的可选导出函数名(逗号分隔)与个数: 旧版 rtlsdr.dll 可能不导出部分函数 }
    property MissingExports: string read FMissing;
    property MissingCount: Integer read FMissingCount;
  end;

  { ---- 本地设备 ---- }
  TRtlDevice = class(TRtlSource)
  private
    FDev: Pointer;
    FLib: TRtlSdrLib;
    FIndex: Integer;
    FGains: TArray<Double>;
  public
    constructor Create(ALib: TRtlSdrLib);
    destructor Destroy; override;
    function Open(Index: Integer; out Err: string): Boolean;
    function SetSampleRate(Rate: Cardinal): Boolean; override;
    function SetCenterFreq(FreqHz: Cardinal): Boolean; override;
    function SetGainMode(Manual: Boolean): Boolean; override;
    function SetGain(GainTenthDb: Integer): Boolean; override;
    function ReadSamples(Buf: Pointer; ByteCount: Integer;
      out BytesRead: Integer): Boolean; override;
    function GetTunerType: Integer; override;
    function GetTunerGains: TArray<Double>; override;
    procedure Close; override;
    function IsOpen: Boolean; override;
    property Lib: TRtlSdrLib read FLib;
  end;

{ 枚举本地 RTL-SDR 设备 }
function EnumerateRtlDevices(const ALib: TRtlSdrLib): TDeviceInfoArray;
{ 8bit IQ -> 复数 (对应 rtltcp.__raw_to_iq): (v - 127.5) / 127.5 }
procedure RawToIQ(Raw: PByte; Samples: Integer; out Re, Im: TArray<Double>);

var
  GRtlLib: TRtlSdrLib = nil;

implementation

{ ============================ TRtlSdrLib ============================ }

constructor TRtlSdrLib.Create;
begin
  inherited;
  FLib := 0;
end;

destructor TRtlSdrLib.Destroy;
begin
  if FLib <> 0 then
    FreeLibrary(FLib);
  inherited;
end;

function TRtlSdrLib.Load(const ADllPath: string; out Err: string): Boolean;
var
  Path: string;

  procedure AddMiss(const AName: string);
  begin
    if FMissing <> '' then
      FMissing := FMissing + ', ';
    FMissing := FMissing + AName;
    Inc(FMissingCount);
  end;

begin
  Result := False;
  Err := '';
  FMissing := '';
  FMissingCount := 0;
  if FLib <> 0 then
  begin
    Result := True;
    Exit;
  end;

  Path := ADllPath;
  if Path = '' then
    Path := 'rtlsdr.dll';

  FLib := Winapi.Windows.LoadLibrary(PChar(Path));
  if FLib = 0 then
  begin
    Err := Format('无法加载 %s (错误码 %d)', [Path, GetLastError]);
    Exit;
  end;

  @rtlsdr_open := GetProcAddress(FLib, 'rtlsdr_open');
  @rtlsdr_close := GetProcAddress(FLib, 'rtlsdr_close');
  @rtlsdr_set_sample_rate := GetProcAddress(FLib, 'rtlsdr_set_sample_rate');
  @rtlsdr_get_sample_rate := GetProcAddress(FLib, 'rtlsdr_get_sample_rate');
  @rtlsdr_set_center_freq := GetProcAddress(FLib, 'rtlsdr_set_center_freq');
  @rtlsdr_get_center_freq := GetProcAddress(FLib, 'rtlsdr_get_center_freq');
  @rtlsdr_set_gain_mode := GetProcAddress(FLib, 'rtlsdr_set_gain_mode');
  @rtlsdr_set_tuner_gain := GetProcAddress(FLib, 'rtlsdr_set_tuner_gain');
  @rtlsdr_get_tuner_gain := GetProcAddress(FLib, 'rtlsdr_get_tuner_gain');
  @rtlsdr_get_tuner_gains := GetProcAddress(FLib, 'rtlsdr_get_tuner_gains');
  @rtlsdr_get_tuner_type := GetProcAddress(FLib, 'rtlsdr_get_tuner_type');
  @rtlsdr_reset_buffer := GetProcAddress(FLib, 'rtlsdr_reset_buffer');
  @rtlsdr_read_sync := GetProcAddress(FLib, 'rtlsdr_read_sync');
  @rtlsdr_get_device_count := GetProcAddress(FLib, 'rtlsdr_get_device_count');
  @rtlsdr_get_device_name := GetProcAddress(FLib, 'rtlsdr_get_device_name');
  @rtlsdr_get_device_usb_strings := GetProcAddress(FLib, 'rtlsdr_get_device_usb_strings');
  @rtlsdr_set_tuner_bandwidth := GetProcAddress(FLib, 'rtlsdr_set_tuner_bandwidth');

  if not Assigned(rtlsdr_open) or not Assigned(rtlsdr_close) or
     not Assigned(rtlsdr_read_sync) or not Assigned(rtlsdr_get_device_count) then
  begin
    Err := 'rtlsdr.dll 缺少必需导出函数, 可能不是 rtl-sdr 官方版本';
    FreeLibrary(FLib);
    FLib := 0;
    Exit;
  end;

  { 统计缺失的可选导出: 旧版 rtlsdr.dll 常见缺失, 调用前必须判 Assigned }
  if not Assigned(rtlsdr_set_sample_rate) then AddMiss('rtlsdr_set_sample_rate');
  if not Assigned(rtlsdr_set_center_freq) then AddMiss('rtlsdr_set_center_freq');
  if not Assigned(rtlsdr_set_gain_mode) then AddMiss('rtlsdr_set_gain_mode');
  if not Assigned(rtlsdr_set_tuner_gain) then AddMiss('rtlsdr_set_tuner_gain');
  if not Assigned(rtlsdr_get_tuner_gains) then AddMiss('rtlsdr_get_tuner_gains');
  if not Assigned(rtlsdr_get_tuner_type) then AddMiss('rtlsdr_get_tuner_type');
  if not Assigned(rtlsdr_reset_buffer) then AddMiss('rtlsdr_reset_buffer');
  if not Assigned(rtlsdr_set_tuner_bandwidth) then AddMiss('rtlsdr_set_tuner_bandwidth');

  FDllPath := Path;
  Result := True;
end;

function TRtlSdrLib.Loaded: Boolean;
begin
  Result := FLib <> 0;
end;

{ ============================ TRtlDevice ============================ }

constructor TRtlDevice.Create(ALib: TRtlSdrLib);
begin
  inherited Create;
  FLib := ALib;
  FDev := nil;
  FIndex := -1;
end;

function TRtlDevice.Open(Index: Integer; out Err: string): Boolean;
begin
  Result := False;
  Err := '';
  if (FLib = nil) or not FLib.Loaded then
  begin
    Err := 'rtlsdr.dll 未加载';
    Exit;
  end;

  if FDev <> nil then
    Close;

  if FLib.rtlsdr_open(FDev, Cardinal(Index)) <> 0 then
  begin
    FDev := nil;
    Err := Format('打开设备 %d 失败', [Index]);
    Exit;
  end;

  FIndex := Index;
  Result := True;
end;

function TRtlDevice.SetSampleRate(Rate: Cardinal): Boolean;
begin
  Result := False;
  { 旧版 rtlsdr.dll 可能不导出该函数: 未判空直接调用会跳到地址0造成 AV }
  if (FDev = nil) or not Assigned(FLib.rtlsdr_set_sample_rate) then
    Exit;
  Result := FLib.rtlsdr_set_sample_rate(FDev, Rate) = 0;
end;

function TRtlDevice.SetCenterFreq(FreqHz: Cardinal): Boolean;
begin
  Result := False;
  if (FDev = nil) or not Assigned(FLib.rtlsdr_set_center_freq) then
    Exit;
  Result := FLib.rtlsdr_set_center_freq(FDev, FreqHz) = 0;
  if Result and Assigned(FLib.rtlsdr_reset_buffer) then
    FLib.rtlsdr_reset_buffer(FDev);
end;

function TRtlDevice.SetGainMode(Manual: Boolean): Boolean;
var
  M: LongInt;
begin
  if Manual then
    M := 1
  else
    M := 0;
  Result := False;
  if (FDev = nil) or not Assigned(FLib.rtlsdr_set_gain_mode) then
    Exit;
  Result := FLib.rtlsdr_set_gain_mode(FDev, M) = 0;
end;

function TRtlDevice.SetGain(GainTenthDb: Integer): Boolean;
begin
  Result := False;
  if (FDev = nil) or not Assigned(FLib.rtlsdr_set_tuner_gain) then
    Exit;
  Result := FLib.rtlsdr_set_tuner_gain(FDev, GainTenthDb) = 0;
end;

function TRtlDevice.ReadSamples(Buf: Pointer; ByteCount: Integer;
  out BytesRead: Integer): Boolean;
var
  N: LongInt;
begin
  BytesRead := 0;
  Result := False;
  if (FDev = nil) or not Assigned(FLib.rtlsdr_read_sync) then
    Exit;
  N := 0;
  if FLib.rtlsdr_read_sync(FDev, Buf, ByteCount, @N) = 0 then
  begin
    BytesRead := N;
    Result := N > 0;
  end;
end;

function TRtlDevice.GetTunerType: Integer;
begin
  if (FDev = nil) or not Assigned(FLib.rtlsdr_get_tuner_type) then
    Result := RTLSDR_TUNER_UNKNOWN
  else
    Result := FLib.rtlsdr_get_tuner_type(FDev);
end;

function TRtlDevice.GetTunerGains: TArray<Double>;
var
  Count, I: Integer;
  Gains: TArray<LongInt>;
begin
  if Length(FGains) = 0 then
  begin
    if (FDev <> nil) and Assigned(FLib.rtlsdr_get_tuner_gains) then
    begin
      Count := FLib.rtlsdr_get_tuner_gains(FDev, nil);
      if Count > 0 then
      begin
        SetLength(Gains, Count);
        Count := FLib.rtlsdr_get_tuner_gains(FDev, @Gains[0]);
        if Count > 0 then
        begin
          SetLength(FGains, Count);
          for I := 0 to Count - 1 do
            FGains[I] := Gains[I] / 10.0;
        end;
      end;
    end;
  end;
  Result := FGains;
end;

procedure TRtlDevice.Close;
begin
  if FDev <> nil then
  begin
    { 旧版/裁剪版 DLL 可能不导出 rtlsdr_close, 未判空直接调用会跳到地址 0 }
    if (FLib <> nil) and Assigned(FLib.rtlsdr_close) then
      FLib.rtlsdr_close(FDev);
    FDev := nil;
  end;
  FIndex := -1;
end;

destructor TRtlDevice.Destroy;
begin
  { 必须先关闭设备句柄, 否则 rtlsdr.dll 卸载后 USB 设备仍被占用,
    再次打开会报 usb_open error -12 }
  Close;
  inherited;
end;

function TRtlDevice.IsOpen: Boolean;
begin
  Result := FDev <> nil;
end;

{ ============================ 辅助函数 ============================ }

function EnumerateRtlDevices(const ALib: TRtlSdrLib): TDeviceInfoArray;
var
  Count, I: Integer;
  Prod, Manuf, Ser: array[0..255] of AnsiChar;
  Info: TDeviceInfo;
  NamePtr: PAnsiChar;
begin
  Result := nil;
  if (ALib = nil) or not ALib.Loaded then
    Exit;

  Count := ALib.rtlsdr_get_device_count();
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    FillChar(Prod, SizeOf(Prod), 0);
    FillChar(Manuf, SizeOf(Manuf), 0);
    FillChar(Ser, SizeOf(Ser), 0);
    if Assigned(ALib.rtlsdr_get_device_usb_strings) then
      ALib.rtlsdr_get_device_usb_strings(I, @Manuf[0], @Prod[0], @Ser[0]);
    NamePtr := nil;
    if Assigned(ALib.rtlsdr_get_device_name) then
      NamePtr := ALib.rtlsdr_get_device_name(I);

    Info.Index := I;
    if NamePtr <> nil then
      Info.Name := string(AnsiString(NamePtr))
    else
      Info.Name := string(AnsiString(Prod));
    Info.Manufacturer := string(AnsiString(Manuf));
    Info.Serial := string(AnsiString(Ser));
    Result[I] := Info;
  end;
end;

procedure RawToIQ(Raw: PByte; Samples: Integer; out Re, Im: TArray<Double>);
var
  I: Integer;
  Scale: Double;
begin
  SetLength(Re, Samples);
  SetLength(Im, Samples);
  Scale := 127.5;
  for I := 0 to Samples - 1 do
  begin
    Re[I] := (Raw[I * 2] - Scale) / Scale;
    Im[I] := (Raw[I * 2 + 1] - Scale) / Scale;
  end;
end;

initialization
  GRtlLib := nil;

finalization
  if GRtlLib <> nil then
    FreeAndNil(GRtlLib);

end.
