unit SdrSpectrum;

{
  频谱数据模型: 对应原工程 spectrum.py + scan.update_spectrum

  数据组织:
    TSweep        - 一次扫描(一个时间戳)内的全部频点, 频率(MHz) -> 电平(dB)
    TSpectrumSet  - 多次扫描的集合, 支持范围计算、测量、保存/加载

  文件格式说明:
    原程序 .rfs 为 Python cPickle 二进制, Delphi 无法直接解析。
    本移植版采用等价语义的文本格式 .rfsx (版本 1), 字段与原 ScanInfo 一致。
}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  System.Generics.Defaults, SdrTypes;

type
  TSweep = class
  private
    FPoints: TDictionary<Double, Double>;
    { 排序结果缓存: Paint 一帧内会被 GetExtent/DrawTraces/DrawPeaks/DrawCursor
      反复调用 Sorted, 无缓存时同一份数据要被全量排序 20+ 次, 高 NFFT 时界面假死 }
    FSortDirty: Boolean;
    FCachedFreqs: TArray<Double>;
    FCachedLevels: TArray<Double>;
  public
    TimeStamp: Double;
    FreqCentre: Double;
    constructor Create(ATimeStamp: Double);
    destructor Destroy; override;
    procedure Add(FreqMHz, LevelDb: Double; Merge: Boolean);
    function GetLevel(FreqMHz: Double; out Level: Double): Boolean;
    function Count: Integer;
    function Sorted(out Freqs, Levels: TArray<Double>): Boolean;
    procedure Assign(Source: TSweep);
  end;

  TMeasureResult = record
    Valid: Boolean;
    MinFreq, MaxFreq, MinLevel, MaxLevel: Double;
    PeakFreq, PeakLevel: Double;
    AvgLevel, GMeanLevel, Flatness: Double;
    HbwStart, HbwEnd: Double;
    ObwStart, ObwEnd: Double;
  end;

  TScanInfo = record
    StartMHz, StopMHz, Dwell: Double;
    NFFT: Integer;
    Name: string;
    Gain, Lo, Calibration: Double;
    Tuner: Integer;
    Time: Double;
    Lat, Lon: Double;
    Desc: string;
  end;

  TSpectrumSet = class
  private
    FSweeps: TObjectList<TSweep>;
    function GetCount: Integer;
    function GetSweep(Index: Integer): TSweep;
    function SweepTimeCompare(const L, R: TSweep): Integer;
  public
    Info: TScanInfo;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function EnsureSweep(TimeStamp: Double): TSweep;
    procedure AddPoint(TimeStamp, FreqMHz, LevelDb: Double; Merge: Boolean = True);
    procedure AddPoints(TimeStamp: Double; const Points: TPoint2DArray;
      Merge: Boolean = True);
    procedure Sort;
    procedure RemoveOlder(Keep: Integer);
    function Latest: TSweep;
    function GetExtent(out FMin, FMax, LMin, LMax, TMin, TMax: Double): Boolean;
    property Count: Integer read GetCount;
    property Sweeps[Index: Integer]: TSweep read GetSweep; default;
    procedure SaveToFile(const FileName: string);
    procedure LoadFromFile(const FileName: string);
    procedure ExportCSV(const FileName: string);
  end;

function MeasureSweep(Sweep: TSweep; StartMHz, StopMHz: Double): TMeasureResult;

implementation

{ ============================ TSweep ============================ }

constructor TSweep.Create(ATimeStamp: Double);
begin
  inherited Create;
  FPoints := TDictionary<Double, Double>.Create;
  FSortDirty := True;
  TimeStamp := ATimeStamp;
end;

destructor TSweep.Destroy;
begin
  FPoints.Free;
  inherited;
end;

procedure TSweep.Add(FreqMHz, LevelDb: Double; Merge: Boolean);
var
  Old: Double;
begin
  { 注意: Delphi 的 TDictionary 索引器写入在键不存在时会抛 EListError,
    必须使用 AddOrSetValue }
  if Merge and FPoints.TryGetValue(FreqMHz, Old) then
    FPoints.AddOrSetValue(FreqMHz, (Old + LevelDb) / 2)
  else
    FPoints.AddOrSetValue(FreqMHz, LevelDb);
  { 关键: 任何写入都必须让排序缓存失效, 否则一轮扫频中先画过的
    sweep 会永远返回首次排序的快照, 表现为"画一部分后不再更新" }
  FSortDirty := True;
end;

function TSweep.GetLevel(FreqMHz: Double; out Level: Double): Boolean;
begin
  Result := FPoints.TryGetValue(FreqMHz, Level);
end;

function TSweep.Count: Integer;
begin
  Result := FPoints.Count;
end;

function TSweep.Sorted(out Freqs, Levels: TArray<Double>): Boolean;
var
  Keys: TArray<Double>;
  I: Integer;
begin
  Result := False;

  { 命中缓存: 同一帧内多次取数只排一次序 }
  if (not FSortDirty) and (FCachedFreqs <> nil) then
  begin
    Freqs := FCachedFreqs;
    Levels := FCachedLevels;
    Result := Length(Freqs) > 0;
    Exit;
  end;

  Freqs := nil;
  Levels := nil;
  FCachedFreqs := nil;
  FCachedLevels := nil;
  if FPoints.Count = 0 then
    Exit;

  Keys := FPoints.Keys.ToArray;
  TArray.Sort<Double>(Keys);
  SetLength(Freqs, Length(Keys));
  SetLength(Levels, Length(Keys));
  for I := 0 to High(Keys) do
  begin
    Freqs[I] := Keys[I];
    Levels[I] := FPoints[Keys[I]];
  end;

  FCachedFreqs := Freqs;
  FCachedLevels := Levels;
  FSortDirty := False;
  Result := True;
end;

procedure TSweep.Assign(Source: TSweep);
var
  Pair: TPair<Double, Double>;
begin
  FPoints.Clear;
  for Pair in Source.FPoints do
    FPoints.AddOrSetValue(Pair.Key, Pair.Value);
  FSortDirty := True;
  TimeStamp := Source.TimeStamp;
  FreqCentre := Source.FreqCentre;
end;

{ ============================ TSpectrumSet ============================ }

constructor TSpectrumSet.Create;
begin
  inherited Create;
  FSweeps := TObjectList<TSweep>.Create(True);
end;

destructor TSpectrumSet.Destroy;
begin
  FSweeps.Free;
  inherited;
end;

function TSpectrumSet.SweepTimeCompare(const L, R: TSweep): Integer;
begin
  if L.TimeStamp < R.TimeStamp then
    Result := -1
  else if L.TimeStamp > R.TimeStamp then
    Result := 1
  else
    Result := 0;
end;

procedure TSpectrumSet.Sort;
begin
  FSweeps.Sort(TComparer<TSweep>.Construct(SweepTimeCompare));
end;

procedure TSpectrumSet.Clear;
begin
  FSweeps.Clear;
end;

function TSpectrumSet.GetCount: Integer;
begin
  Result := FSweeps.Count;
end;

function TSpectrumSet.GetSweep(Index: Integer): TSweep;
begin
  Result := FSweeps[Index];
end;

function TSpectrumSet.EnsureSweep(TimeStamp: Double): TSweep;
var
  I: Integer;
begin
  { 同一轮扫频的所有频步共享同一 TimeStamp, 必须精确匹配; 原 0.5 秒容差
    会把相邻多轮扫频并进同一 sweep, 叠加缓存后画面长时间不动 }
  for I := FSweeps.Count - 1 downto 0 do
    if Abs(FSweeps[I].TimeStamp - TimeStamp) < 1.0E-6 then
    begin
      Result := FSweeps[I];
      Exit;
    end;
  Result := TSweep.Create(TimeStamp);
  FSweeps.Add(Result);
end;

procedure TSpectrumSet.AddPoint(TimeStamp, FreqMHz, LevelDb: Double;
  Merge: Boolean);
begin
  EnsureSweep(TimeStamp).Add(FreqMHz, LevelDb, Merge);
end;

{ 批量写入: 一整步频点只做一次 sweep 查找。
  逐点 AddPoint 在高 NFFT 下会退化为 步数×点数×sweeps数 次比较, 主线程
  被彻底占满, 连 WM_PAINT 都排不上, 表现为画面只画一部分后停滞 }
procedure TSpectrumSet.AddPoints(TimeStamp: Double; const Points: TPoint2DArray;
  Merge: Boolean);
var
  Sweep: TSweep;
  I: Integer;
begin
  if Length(Points) = 0 then
    Exit;
  Sweep := EnsureSweep(TimeStamp);
  for I := 0 to High(Points) do
    Sweep.Add(Points[I].X, Points[I].Y, Merge);
end;

procedure TSpectrumSet.RemoveOlder(Keep: Integer);
begin
  if Keep < 1 then
    Keep := 1;
  { 未超限时直接返回, 避免每步都做一次全量排序 }
  if FSweeps.Count <= Keep then
    Exit;
  Sort;
  while FSweeps.Count > Keep do
    FSweeps.Delete(0);
end;

function TSpectrumSet.Latest: TSweep;
begin
  if FSweeps.Count = 0 then
    Result := nil
  else
    Result := FSweeps[FSweeps.Count - 1];
end;

function TSpectrumSet.GetExtent(out FMin, FMax, LMin, LMax, TMin, TMax: Double): Boolean;
var
  I: Integer;
  Freqs, Levels: TArray<Double>;
  Sweep: TSweep;
begin
  Result := False;
  FMin := 0; FMax := 0; LMin := 0; LMax := 0; TMin := 0; TMax := 0;
  if FSweeps.Count = 0 then
    Exit;

  FMin := MaxDouble;
  FMax := -MaxDouble;
  LMin := MaxDouble;
  LMax := -MaxDouble;
  TMin := MaxDouble;
  TMax := -MaxDouble;

  for I := 0 to FSweeps.Count - 1 do
  begin
    Sweep := FSweeps[I];
    if not Sweep.Sorted(Freqs, Levels) then
      Continue;
    if Freqs[0] < FMin then
      FMin := Freqs[0];
    if Freqs[High(Freqs)] > FMax then
      FMax := Freqs[High(Freqs)];
    for var J := 0 to High(Levels) do
    begin
      if Levels[J] < LMin then
        LMin := Levels[J];
      if Levels[J] > LMax then
        LMax := Levels[J];
    end;
    if Sweep.TimeStamp < TMin then
      TMin := Sweep.TimeStamp;
    if Sweep.TimeStamp > TMax then
      TMax := Sweep.TimeStamp;
    Result := True;
  end;
end;

{ ============================ 测量 ============================ }

function MeasureSweep(Sweep: TSweep; StartMHz, StopMHz: Double): TMeasureResult;
var
  Freqs, Levels: TArray<Double>;
  I, N, PeakIdx, Lo, Hi, Lo2, Hi2: Integer;
  SumLin, GMeanLog, TotalLin, Accum, HalfPower, Gate: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Sweep = nil) or not Sweep.Sorted(Freqs, Levels) then
    Exit;

  N := Length(Freqs);
  PeakIdx := -1;
  for I := 0 to N - 1 do
    if (Freqs[I] >= StartMHz) and (Freqs[I] <= StopMHz) then
      if (PeakIdx < 0) or (Levels[I] > Levels[PeakIdx]) then
        PeakIdx := I;

  if PeakIdx < 0 then
    Exit;

  Result.Valid := True;
  Result.PeakFreq := Freqs[PeakIdx];
  Result.PeakLevel := Levels[PeakIdx];

  Lo := PeakIdx;
  Hi := PeakIdx;
  while (Lo > 0) and (Freqs[Lo] >= StartMHz) do
    Dec(Lo);
  while (Hi < N - 1) and (Freqs[Hi] <= StopMHz) do
    Inc(Hi);

  Result.MinFreq := Freqs[Lo];
  Result.MaxFreq := Freqs[Hi];
  Result.MinLevel := Levels[Lo];
  Result.MaxLevel := Levels[Lo];
  SumLin := 0;
  GMeanLog := 0;
  for I := Lo to Hi do
  begin
    if Levels[I] < Result.MinLevel then
      Result.MinLevel := Levels[I];
    if Levels[I] > Result.MaxLevel then
      Result.MaxLevel := Levels[I];
    SumLin := SumLin + DbToLevel(Levels[I]);
    GMeanLog := GMeanLog + Ln(Max(DbToLevel(Levels[I]), 1.0E-30));
  end;

  if Hi >= Lo then
  begin
    Result.AvgLevel := LevelToDb(SumLin / (Hi - Lo + 1));
    Result.GMeanLevel := LevelToDb(Exp(GMeanLog / (Hi - Lo + 1)));
    if Result.AvgLevel <> 0 then
      Result.Flatness := Result.GMeanLevel / Result.AvgLevel
    else
      Result.Flatness := 0;
  end;

  { -3dB 带宽 }
  HalfPower := Result.PeakLevel - 3;
  I := PeakIdx;
  Result.HbwStart := Freqs[PeakIdx];
  Result.HbwEnd := Freqs[PeakIdx];
  while (I > Lo) and (Levels[I] > HalfPower) do
    Dec(I);
  Result.HbwStart := Freqs[I];
  I := PeakIdx;
  while (I < Hi) and (Levels[I] > HalfPower) do
    Inc(I);
  Result.HbwEnd := Freqs[I];

  { OBW: 仅在"峰值 -40 dB"以上的连续谱段内累计功率, 两侧各取 0.5% 总功率
    (若直接用全频段累加, 宽带底噪会主导总功率, 使 OBW 被低估) }
  Gate := Result.PeakLevel - 40;
  Lo2 := PeakIdx;
  while (Lo2 > Lo) and (Levels[Lo2 - 1] >= Gate) do
    Dec(Lo2);
  Hi2 := PeakIdx;
  while (Hi2 < Hi) and (Levels[Hi2 + 1] >= Gate) do
    Inc(Hi2);

  TotalLin := 0;
  for I := Lo2 to Hi2 do
    TotalLin := TotalLin + DbToLevel(Levels[I]);

  Result.ObwStart := Freqs[PeakIdx];
  Result.ObwEnd := Freqs[PeakIdx];
  if TotalLin > 0 then
  begin
    Accum := 0;
    I := PeakIdx;
    while (I > Lo2) and (Accum < TotalLin * 0.005) do
    begin
      Accum := Accum + DbToLevel(Levels[I]);
      Dec(I);
    end;
    Result.ObwStart := Freqs[I];

    Accum := 0;
    I := PeakIdx;
    while (I < Hi2) and (Accum < TotalLin * 0.005) do
    begin
      Accum := Accum + DbToLevel(Levels[I]);
      Inc(I);
    end;
    Result.ObwEnd := Freqs[I];
  end;
end;

{ ============================ 存取 ============================ }

procedure TSpectrumSet.SaveToFile(const FileName: string);
var
  Lines: TStringList;
  I, J: Integer;
  Freqs, Levels: TArray<Double>;
  SB: TStringBuilder;
begin
  Sort;
  Lines := TStringList.Create;
  try
    Lines.Add('RTLSDR Scanner Spectrum');
    Lines.Add('Version=1');
    Lines.Add(Format('Start=%.6f', [Info.StartMHz]));
    Lines.Add(Format('Stop=%.6f', [Info.StopMHz]));
    Lines.Add(Format('Dwell=%.6f', [Info.Dwell]));
    Lines.Add(Format('Nfft=%d', [Info.NFFT]));
    Lines.Add('Device=' + Info.Name);
    Lines.Add(Format('Gain=%.3f', [Info.Gain]));
    Lines.Add(Format('LO=%.6f', [Info.Lo]));
    Lines.Add(Format('Calibration=%.6f', [Info.Calibration]));
    Lines.Add(Format('Tuner=%d', [Info.Tuner]));
    Lines.Add(Format('Time=%.6f', [Info.Time]));
    Lines.Add(Format('Latitude=%.8f', [Info.Lat]));
    Lines.Add(Format('Longitude=%.8f', [Info.Lon]));
    Lines.Add('Description=' + Info.Desc);

    SB := TStringBuilder.Create;
    try
      for I := 0 to FSweeps.Count - 1 do
      begin
        if not FSweeps[I].Sorted(Freqs, Levels) then
          Continue;
        Lines.Add(Format('[Sweep %.6f]', [FSweeps[I].TimeStamp]));
        { 用 StringBuilder 追加, 避免 string 反复拼接的 O(n^2) 拷贝 }
        SB.Clear;
        for J := 0 to High(Freqs) do
        begin
          if SB.Length > 0 then
            SB.Append(';');
          SB.Append(Format('%.6f,%.4f', [Freqs[J], Levels[J]]));
          if SB.Length > 30000 then
          begin
            Lines.Add(SB.ToString);
            SB.Clear;
          end;
        end;
        if SB.Length > 0 then
          Lines.Add(SB.ToString);
      end;
    finally
      SB.Free;
    end;

    Lines.SaveToFile(FileName, TEncoding.UTF8);
  finally
    Lines.Free;
  end;
end;

procedure TSpectrumSet.LoadFromFile(const FileName: string);
var
  Lines, Pairs: TStringList;
  I, J: Integer;
  Line, TimeStr: string;
  Sweep: TSweep;
  P: Integer;
  F, L: Double;
  Key, Val: string;
begin
  Lines := TStringList.Create;
  Pairs := TStringList.Create;
  try
    Lines.LoadFromFile(FileName, TEncoding.UTF8);
    Clear;
    Sweep := nil;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then
        Continue;

      if (Length(Line) > 1) and (Line[1] = '[') then
      begin
        TimeStr := StringReplace(StringReplace(Line, '[Sweep', '', [rfReplaceAll]),
          ']', '', [rfReplaceAll]);
        Sweep := TSweep.Create(StrToFloatDef(Trim(TimeStr), 0));
        FSweeps.Add(Sweep);
        Continue;
      end;

      P := Pos('=', Line);
      if (P > 0) and (Sweep = nil) then
      begin
        Key := Copy(Line, 1, P - 1);
        Val := Copy(Line, P + 1, Length(Line));
        if SameText(Key, 'Start') then
          Info.StartMHz := StrToFloatDef(Val, 87)
        else if SameText(Key, 'Stop') then
          Info.StopMHz := StrToFloatDef(Val, 108)
        else if SameText(Key, 'Dwell') then
          Info.Dwell := StrToFloatDef(Val, 0.1)
        else if SameText(Key, 'Nfft') then
          Info.NFFT := StrToIntDef(Val, 1024)
        else if SameText(Key, 'Device') then
          Info.Name := Val
        else if SameText(Key, 'Gain') then
          Info.Gain := StrToFloatDef(Val, 0)
        else if SameText(Key, 'LO') then
          Info.Lo := StrToFloatDef(Val, 0)
        else if SameText(Key, 'Calibration') then
          Info.Calibration := StrToFloatDef(Val, 0)
        else if SameText(Key, 'Tuner') then
          Info.Tuner := StrToIntDef(Val, 0)
        else if SameText(Key, 'Time') then
          Info.Time := StrToFloatDef(Val, 0)
        else if SameText(Key, 'Latitude') then
          Info.Lat := StrToFloatDef(Val, 0)
        else if SameText(Key, 'Longitude') then
          Info.Lon := StrToFloatDef(Val, 0)
        else if SameText(Key, 'Description') then
          Info.Desc := Val;
        Continue;
      end;

      if Sweep = nil then
        Continue;

      Pairs.Clear;
      Pairs.Delimiter := ';';
      Pairs.StrictDelimiter := True;
      Pairs.DelimitedText := Line;
      for J := 0 to Pairs.Count - 1 do
      begin
        Val := Trim(Pairs[J]);
        P := Pos(',', Val);
        if P = 0 then
          Continue;
        F := StrToFloatDef(Copy(Val, 1, P - 1), 0);
        L := StrToFloatDef(Copy(Val, P + 1, Length(Val)), 0);
        Sweep.Add(F, L, False);
      end;
    end;
  finally
    Pairs.Free;
    Lines.Free;
  end;
end;

procedure TSpectrumSet.ExportCSV(const FileName: string);
var
  Lines: TStringList;
  I, J: Integer;
  Freqs, Levels: TArray<Double>;
begin
  Sort;
  Lines := TStringList.Create;
  try
    Lines.Add('Time,Frequency (MHz),Level (dB)');
    for I := 0 to FSweeps.Count - 1 do
    begin
      if not FSweeps[I].Sorted(Freqs, Levels) then
        Continue;
      for J := 0 to High(Freqs) do
        Lines.Add(Format('%.3f,%.6f,%.4f',
          [FSweeps[I].TimeStamp, Freqs[J], Levels[J]]));
    end;
    Lines.SaveToFile(FileName, TEncoding.UTF8);
  finally
    Lines.Free;
  end;
end;

end.
