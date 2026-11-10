unit SdrDsp;

{
  数字信号处理: 对应原工程 matplotlib.mlab.psd / numpy 窗函数 / spectrum.py 的平滑与峰值检测

  与原程序保持一致的计算口径:
    PSD   : Pxx = |FFT(x*w)|^2 / (Fs * sum(w^2)), 单边谱非 DC/Nyquist 分量 x2
            多段 Welch 平均, noverlap = round(NFFT * overlap)
    频率轴: 0 .. Fs/2, 叠加到当前步进中心频率上形成绝对频率
}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, SdrTypes;

procedure MakeWindow(Kind: TWindowKind; N: Integer; out Win: TArray<Double>);

{ 就地基2 FFT, 长度必须是 2 的幂 }
procedure FFTInPlace(var Re, Im: TArray<Double>);

{ Welch PSD。Re/Im 为已解调的复数样本, FreqMHz 为相对 0..Fs/2 的频率(MHz), Power 为线性功率谱密度 }
procedure ComputePSD(const Re, Im: TArray<Double>; NFFT: Integer; Overlap: Double;
  Kind: TWindowKind; Fs: Double; out FreqMHz, Power: TArray<Double>);

{ 对应 spectrum.smooth_sweep: 边缘镜像 + 卷积平滑 }
procedure SmoothSweep(const Freqs, Levels: TArray<Double>; Kind: TWindowKind;
  Ratio: Integer; out OutLevels: TArray<Double>);

{ 对应 spectrum.get_peaks: 局部极大值 }
procedure FindPeaks(const Levels: TArray<Double>; Threshold: Double;
  out PeakIdx: TArray<Integer>);

{ 对应 spectrum.diff_spectrum }
procedure DiffSpectrum(const Levels: TArray<Double>; out OutLevels: TArray<Double>);

implementation

procedure MakeWindow(Kind: TWindowKind; N: Integer; out Win: TArray<Double>);
var
  I: Integer;
  T: Double;
begin
  SetLength(Win, N);
  if N <= 1 then
  begin
    if N = 1 then
      Win[0] := 1;
    Exit;
  end;

  for I := 0 to N - 1 do
  begin
    T := I / (N - 1);
    case Kind of
      wkBartlett:
        Win[I] := 1 - Abs(2 * T - 1);
      wkBlackman:
        Win[I] := 0.42 - 0.5 * Cos(2 * Pi * T) + 0.08 * Cos(4 * Pi * T);
      wkHamming:
        Win[I] := 0.54 - 0.46 * Cos(2 * Pi * T);
    else { wkHanning }
      Win[I] := 0.5 - 0.5 * Cos(2 * Pi * T);
    end;
  end;
end;

procedure FFTInPlaceTab(var Re, Im: TArray<Double>;
  const CosTab, SinTab: TArray<Double>);
var
  N, I, J, K, Len, Half, Block, Stride, Idx: Integer;
  TR, TI, WR, WI, CosV, SinV, Tmpr, Tempi: Double;
begin
  N := Length(Re);
  if (N < 2) or (Length(Im) <> N) then
    Exit;

  { 位反转重排 }
  J := 0;
  for I := 1 to N - 1 do
  begin
    K := N shr 1;
    while (J and K) <> 0 do
    begin
      J := J xor K;
      K := K shr 1;
    end;
    J := J xor K;
    if I < J then
    begin
      TR := Re[I]; Re[I] := Re[J]; Re[J] := TR;
      TI := Im[I]; Im[I] := Im[J]; Im[J] := TI;
    end;
  end;

  { 蝶形运算: 旋转因子按步长查表, 内层不再做三角函数 }
  Len := 2;
  while Len <= N do
  begin
    Half := Len shr 1;
    Stride := N div Len;
    Block := 0;
    while Block < N do
    begin
      for K := 0 to Half - 1 do
      begin
        Idx := K * Stride;
        CosV := CosTab[Idx];
        SinV := SinTab[Idx];
        I := Block + K;
        J := I + Half;
        WR := Re[J] * CosV - Im[J] * SinV;
        WI := Re[J] * SinV + Im[J] * CosV;
        Tmpr := Re[I] - WR;
        Tempi := Im[I] - WI;
        Re[I] := Re[I] + WR;
        Im[I] := Im[I] + WI;
        Re[J] := Tmpr;
        Im[J] := Tempi;
      end;
      Inc(Block, Len);
    end;
    Len := Len shl 1;
  end;
end;

procedure FFTInPlace(var Re, Im: TArray<Double>);
var
  N, I: Integer;
  CosTab, SinTab: TArray<Double>;
begin
  N := Length(Re);
  if (N < 2) or (Length(Im) <> N) then
    Exit;
  SetLength(CosTab, N shr 1);
  SetLength(SinTab, N shr 1);
  for I := 0 to (N shr 1) - 1 do
  begin
    CosTab[I] := Cos(-2 * Pi * I / N);
    SinTab[I] := Sin(-2 * Pi * I / N);
  end;
  FFTInPlaceTab(Re, Im, CosTab, SinTab);
end;

procedure ComputePSD(const Re, Im: TArray<Double>; NFFT: Integer; Overlap: Double;
  Kind: TWindowKind; Fs: Double; out FreqMHz, Power: TArray<Double>);
var
  Total, SegLen, Noverlap, StepLen, SegCount, I, K, BinCount, Pos, Seg: Integer;
  Win, SRe, SIm, Acc, CosTab, SinTab: TArray<Double>;
  SumWin2, Mean, MeanIm, Freq: Double;
begin
  FreqMHz := nil;
  Power := nil;

  Total := Length(Re);
  if (Total < 2) or (Length(Im) <> Total) then
    Exit;

  { 每段长度取 min(NFFT, 可用样本数) 向下取 2 的幂 }
  SegLen := 1;
  while SegLen * 2 <= Min(NFFT, Total) do
    SegLen := SegLen * 2;
  if SegLen < 2 then
    Exit;

  MakeWindow(Kind, SegLen, Win);
  SumWin2 := 0;
  for I := 0 to SegLen - 1 do
    SumWin2 := SumWin2 + Win[I] * Win[I];
  if SumWin2 <= 0 then
    Exit;

  Noverlap := Round(SegLen * Overlap);
  if Noverlap >= SegLen then
    Noverlap := SegLen div 2;
  StepLen := SegLen - Noverlap;
  if StepLen < 1 then
    StepLen := SegLen;

  BinCount := SegLen div 2 + 1;
  SetLength(Acc, BinCount);
  for K := 0 to BinCount - 1 do
    Acc[K] := 0;
  SegCount := 0;

  SetLength(SRe, SegLen);
  SetLength(SIm, SegLen);

  { 旋转因子只依赖段长, 在整段循环前算一次, 所有分段复用 }
  SetLength(CosTab, SegLen shr 1);
  SetLength(SinTab, SegLen shr 1);
  for I := 0 to (SegLen shr 1) - 1 do
  begin
    CosTab[I] := Cos(-2 * Pi * I / SegLen);
    SinTab[I] := Sin(-2 * Pi * I / SegLen);
  end;

  Pos := 0;
  while Pos + SegLen <= Total do
  begin
    { detrend: 去均值 (mlab 默认 detrend_mean, 复数信号实部/虚部各自去均值) }
    Mean := 0;
    MeanIm := 0;
    for I := 0 to SegLen - 1 do
    begin
      Mean := Mean + Re[Pos + I];
      MeanIm := MeanIm + Im[Pos + I];
    end;
    Mean := Mean / SegLen;
    MeanIm := MeanIm / SegLen;

    for I := 0 to SegLen - 1 do
    begin
      SRe[I] := (Re[Pos + I] - Mean) * Win[I];
      SIm[I] := (Im[Pos + I] - MeanIm) * Win[I];
    end;

    FFTInPlaceTab(SRe, SIm, CosTab, SinTab);

    for K := 0 to BinCount - 1 do
      Acc[K] := Acc[K] + (SRe[K] * SRe[K] + SIm[K] * SIm[K]);

    Inc(SegCount);
    Inc(Pos, StepLen);
  end;

  if SegCount = 0 then
    Exit;

  SetLength(FreqMHz, BinCount);
  SetLength(Power, BinCount);
  for K := 0 to BinCount - 1 do
  begin
    { 与原程序 matplotlib.mlab.psd 完全对齐:
      1) 调用方传入的 Fs 是 SAMPLE_RATE/1e6 = 2.0 (MHz), 不是 2e6 (Hz),
         所以按 Fs/1e6 归一化;
      2) 复数 IQ 走 twosided 分支, scaling_factor = 1, 不做单边谱 *2。
      此前按 Hz 归一化又乘 2, 整体电平比原程序低约 57 dB。 }
    Power[K] := Acc[K] / (SegCount * (Fs / 1.0E6) * SumWin2);
    Freq := K * Fs / SegLen;
    FreqMHz[K] := Freq / 1.0E6;
  end;
end;

procedure SmoothSweep(const Freqs, Levels: TArray<Double>; Kind: TWindowKind;
  Ratio: Integer; out OutLevels: TArray<Double>);
var
  N, WinLen, I, K, HalfL: Integer;
  Win: TArray<Double>;
  SumW, Acc: Double;

  { 镜像延拓取数: 越界时按边界反射, 保证中心区完全对称 }
  function MirrorAt(Index: Integer): Double;
  var
    J: Integer;
  begin
    J := Index;
    while (J < 0) or (J > N - 1) do
    begin
      if J < 0 then
        J := -J
      else
        J := 2 * (N - 1) - J;
      if J < 0 then
        J := 0
      else if J > N - 1 then
        J := N - 1;
    end;
    Result := Levels[J];
  end;

begin
  N := Length(Levels);
  SetLength(OutLevels, N);
  if N = 0 then
    Exit;

  if Ratio < 1 then
    Ratio := 1;
  WinLen := N div Ratio;
  if WinLen < 2 then
    WinLen := 2;
  if WinLen > N then
    WinLen := N;

  MakeWindow(Kind, WinLen, Win);
  SumW := 0;
  for I := 0 to WinLen - 1 do
    SumW := SumW + Win[I];
  if SumW = 0 then
  begin
    for I := 0 to N - 1 do
      OutLevels[I] := Levels[I];
    Exit;
  end;

  { 中心对齐滑动平均: 窗口中心落在 I 上, 峰值位置不会漂移 }
  HalfL := (WinLen - 1) div 2;
  for I := 0 to N - 1 do
  begin
    Acc := 0;
    for K := 0 to WinLen - 1 do
      Acc := Acc + MirrorAt(I - HalfL + K) * Win[K];
    OutLevels[I] := Acc / SumW;
  end;
end;

procedure FindPeaks(const Levels: TArray<Double>; Threshold: Double;
  out PeakIdx: TArray<Integer>);
var
  I, Count: Integer;
begin
  SetLength(PeakIdx, 0);
  Count := 0;
  for I := 1 to Length(Levels) - 2 do
  begin
    if Levels[I] < Threshold then
      Continue;
    if (Levels[I] > Levels[I - 1]) and (Levels[I] > Levels[I + 1]) then
    begin
      SetLength(PeakIdx, Count + 1);
      PeakIdx[Count] := I;
      Inc(Count);
    end;
  end;
end;

procedure DiffSpectrum(const Levels: TArray<Double>; out OutLevels: TArray<Double>);
var
  I: Integer;
begin
  SetLength(OutLevels, Length(Levels));
  for I := 1 to Length(Levels) - 1 do
    OutLevels[I - 1] := Levels[I] - Levels[I - 1];
  if Length(Levels) > 0 then
    OutLevels[Length(Levels) - 1] := 0;
end;

end.
