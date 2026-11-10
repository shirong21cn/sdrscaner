unit SdrPlot;

{
  二维频谱图控件: 对应原工程 plot_spect.py (matplotlib 绘制部分) 的自绘实现

  特性:
    - 多次扫描按时间渐变叠加绘制
    - 自适应频率/电平范围, 或使用配置的固定范围
    - 峰值标记、鼠标十字读数(频率/电平)
    - 双缓冲绘制, 无闪烁
}

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls,
  SdrTypes, SdrSpectrum, SdrSettings;

const
  { 重绘节流间隔(ms): 扫描时数据每步到达一次, 全量重绘跟不上会导致界面假死 }
  REDRAW_INTERVAL = Cardinal(120);

type
  TPlotPanel = class(TCustomControl)
  private
    FSpectrum: TSpectrumSet;
    FSettings: TSdrSettings;
    FDrawArea: TRect;
    FMouseIn: Boolean;
    FMouseX: Integer;
    FMouseY: Integer;
    FShowPeaks: Boolean;
    FLastRedraw: Cardinal;
    FRedrawTimer: TTimer;
    { 数据已变但尚未上屏: 由常驻定时器兜底补刷, 防止重绘请求在
      消息队列繁忙时被永久丢失 }
    FDataDirty: Boolean;
    { 上一次真正完成绘制(进入 Paint)的时刻 }
    FLastPaint: Cardinal;
    { 自动量程导致 Y 范围变化时通知界面同步显示 }
    FOnRangeChanged: TNotifyEvent;
    procedure SetSpectrum(const Value: TSpectrumSet);
    procedure CalcRange(out XMin, XMax, YMin, YMax: Double);
    function FreqToX(Freq, XMin, XMax: Double): Integer;
    function DbToY(Db, YMin, YMax: Double): Integer;
    function NearestIndex(const Freqs: TArray<Double>; Value: Double): Integer;
    procedure DoRedrawTimer(Sender: TObject);
    procedure DoMouseLeave(Sender: TObject);
    procedure DrawBack;
    procedure DrawGrid(const R: TRect; XMin, XMax, YMin, YMax: Double);
    procedure DrawTraces(const R: TRect; XMin, XMax, YMin, YMax: Double);
    procedure DrawPeaks(const R: TRect; XMin, XMax, YMin, YMax: Double);
    procedure DrawCursor(const R: TRect; XMin, XMax, YMin, YMax: Double);
    function NiceStep(Span: Double; TargetTicks: Integer): Double;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Redraw;
    procedure ForceRedraw;
    property Spectrum: TSpectrumSet read FSpectrum write SetSpectrum;
    property Settings: TSdrSettings read FSettings write FSettings;
    property ShowPeaks: Boolean read FShowPeaks write FShowPeaks;
    property OnRangeChanged: TNotifyEvent read FOnRangeChanged write FOnRangeChanged;
  end;

implementation

{ 按比例混合两个颜色: Alpha=0 取 Bg, Alpha=255 取 Fore }
function ColorBlend(Fore, Back: TColor; Alpha: Byte): TColor;
var
  F, B: LongInt;
  FR, FG, FB, BR, BG, BB: Integer;
begin
  F := ColorToRGB(Fore);
  B := ColorToRGB(Back);
  FR := F and $FF; FG := (F shr 8) and $FF; FB := (F shr 16) and $FF;
  BR := B and $FF; BG := (B shr 8) and $FF; BB := (B shr 16) and $FF;
  Result := TColor(
    (BR + (FR - BR) * Alpha div 255) or
    ((BG + (FG - BG) * Alpha div 255) shl 8) or
    ((BB + (FB - BB) * Alpha div 255) shl 16));
end;

constructor TPlotPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  FShowPeaks := True;
  FMouseIn := False;
  Color := $00202020;
  FLastRedraw := 0;
  FDataDirty := False;
  FLastPaint := GetTickCount;
  FRedrawTimer := TTimer.Create(Self);
  { 常驻 100ms 轮询: 只做一次布尔判断, 开销可忽略, 但能保证脏数据一定上屏 }
  FRedrawTimer.Interval := 100;
  FRedrawTimer.OnTimer := DoRedrawTimer;
  FRedrawTimer.Enabled := True;
  OnMouseLeave := DoMouseLeave;
end;

destructor TPlotPanel.Destroy;
begin
  if FRedrawTimer <> nil then
    FRedrawTimer.Enabled := False;
  inherited;
end;

procedure TPlotPanel.DoRedrawTimer(Sender: TObject);
begin
  { 常驻轮询: 只在存在未上屏的脏数据时补刷, 定时器本身保持开启,
    否则一次触发后就永久停摆, 末帧会丢失 }
  if FDataDirty then
    ForceRedraw;
end;

procedure TPlotPanel.DoMouseLeave(Sender: TObject);
begin
  if FMouseIn then
  begin
    FMouseIn := False;
    Redraw;
  end;
end;

procedure TPlotPanel.SetSpectrum(const Value: TSpectrumSet);
begin
  FSpectrum := Value;
  ForceRedraw;
end;

procedure TPlotPanel.ForceRedraw;
begin
  { 脏标记延后到 Paint 结束才清, 防止 Invalidate 被消息泵吞掉后画面永久停更 }
  FDataDirty := True;
  FLastRedraw := GetTickCount;
  if HandleAllocated then
    Invalidate;
end;

{ 节流重绘: 到间隔立即刷, 否则只置脏由常驻定时器兜底补刷 }
procedure TPlotPanel.Redraw;
begin
  FDataDirty := True;
  if not HandleAllocated then
    Exit;
  if GetTickCount - FLastRedraw < REDRAW_INTERVAL then
    Exit;
  FLastRedraw := GetTickCount;
  { 距上一次真正绘制过久, 说明 Invalidate 的 WM_PAINT 被扫描数据消息挤掉了,
    此时改用 Repaint 同步出帧, 否则画面会停在中途 }
  if GetTickCount - FLastPaint > 400 then
    Repaint
  else
    Invalidate;
end;

procedure TPlotPanel.Resize;
begin
  inherited;
  ForceRedraw;
end;

function TPlotPanel.NiceStep(Span: Double; TargetTicks: Integer): Double;
var
  Raw, Mag, Norm: Double;
begin
  if (Span <= 0) or (TargetTicks < 1) then
  begin
    Result := 1;
    Exit;
  end;
  Raw := Span / TargetTicks;
  Mag := Power(10, Floor(Log10(Raw)));
  Norm := Raw / Mag;
  if Norm <= 1 then
    Result := Mag
  else if Norm <= 2 then
    Result := 2 * Mag
  else if Norm <= 5 then
    Result := 5 * Mag
  else
    Result := 10 * Mag;
end;

procedure TPlotPanel.CalcRange(out XMin, XMax, YMin, YMax: Double);
var
  FMin, FMax, LMin, LMax, TMin, TMax: Double;
begin
  XMin := FSettings.StartMHz;
  XMax := FSettings.StopMHz;
  YMin := FSettings.YMin;
  YMax := FSettings.YMax;

  if (FSpectrum <> nil) and FSpectrum.GetExtent(FMin, FMax, LMin, LMax, TMin, TMax) then
  begin
    if FSettings.AutoF then
    begin
      XMin := FMin;
      XMax := FMax;
    end;
    if FSettings.AutoL then
    begin
      YMin := Floor(LMin / 10) * 10;
      YMax := Ceil((LMax + 5) / 10) * 10;
    end;
  end;

  if XMax <= XMin then
    XMax := XMin + 1;
  if YMax <= YMin then
    YMax := YMin + 10;

  { 自动量程时把实际生效的 Y 范围回写并通知界面,
    否则坐标轴已自动缩放, YMin/YMax 输入框却仍显示旧值 }
  if FSettings.AutoL and
     ((Abs(YMin - FSettings.YMin) > 0.05) or (Abs(YMax - FSettings.YMax) > 0.05)) then
  begin
    FSettings.YMin := YMin;
    FSettings.YMax := YMax;
    if Assigned(FOnRangeChanged) then
      FOnRangeChanged(Self);
  end;
end;

function TPlotPanel.FreqToX(Freq, XMin, XMax: Double): Integer;
begin
  if XMax - XMin <= 0 then
    Result := FDrawArea.Left
  else
    Result := FDrawArea.Left +
      Round((Freq - XMin) / (XMax - XMin) * FDrawArea.Width);
end;

function TPlotPanel.DbToY(Db, YMin, YMax: Double): Integer;
begin
  if YMax - YMin <= 0 then
    Result := FDrawArea.Bottom
  else
    Result := FDrawArea.Bottom -
      Round((Db - YMin) / (YMax - YMin) * FDrawArea.Height);
end;

procedure TPlotPanel.DrawBack;
begin
  { 控件本身已开 DoubleBuffered, 直接填充即可;
    原先每次 Paint 新建整幅 TBitmap 纯属浪费 }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FSettings.BackgroundColour;
  Canvas.FillRect(ClientRect);
end;

procedure TPlotPanel.DrawGrid(const R: TRect; XMin, XMax, YMin, YMax: Double);
var
  StepX, StepY, F, D, Span: Double;
  X, Y, Precision: Integer;
  Txt: string;
begin
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := FSettings.LabelColour;
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Size := 8;

  Span := XMax - XMin;
  if Span >= 100 then
    Precision := 0
  else if Span >= 10 then
    Precision := 1
  else if Span >= 1 then
    Precision := 3
  else
    Precision := 4;

  StepX := NiceStep(Span, 10);
  F := Ceil(XMin / StepX) * StepX;
  while F <= XMax + 1.0E-9 do
  begin
    X := FreqToX(F, XMin, XMax);
    Canvas.Pen.Color := $00404040;
    Canvas.Pen.Style := psSolid;
    Canvas.MoveTo(X, R.Top);
    Canvas.LineTo(X, R.Bottom);

    case Precision of
      0: Txt := FormatFloat('0', F);
      1: Txt := FormatFloat('0.0', F);
      3: Txt := FormatFloat('0.000', F);
    else
      Txt := FormatFloat('0.0000', F);
    end;
    Canvas.TextOut(X - Canvas.TextWidth(Txt) div 2, R.Bottom + 4, Txt);
    F := F + StepX;
  end;

  StepY := NiceStep(YMax - YMin, 8);
  D := Ceil(YMin / StepY) * StepY;
  while D <= YMax + 1.0E-9 do
  begin
    Y := DbToY(D, YMin, YMax);
    Canvas.Pen.Color := $00404040;
    Canvas.MoveTo(R.Left, Y);
    Canvas.LineTo(R.Right, Y);
    Txt := FormatFloat('0', D);
    Canvas.TextOut(R.Left - Canvas.TextWidth(Txt) - 6, Y - Canvas.TextHeight(Txt) div 2, Txt);
    D := D + StepY;
  end;

  Canvas.Pen.Color := $00A0A0A0;
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(R.Left, R.Top, R.Right + 1, R.Bottom + 1);

  Canvas.Font.Color := FSettings.LabelColour;
  Txt := 'Frequency (MHz)';
  Canvas.TextOut(R.Left + (R.Width - Canvas.TextWidth(Txt)) div 2, Height - 20, Txt);
  Canvas.Font.Style := [fsBold];
  Canvas.TextOut(4, 6, 'Power (dB)');
  Canvas.Font.Style := [];

  if (FSpectrum <> nil) and (FSpectrum.Info.Desc <> '') then
  begin
    Canvas.TextOut(R.Left + 8, R.Top + 6, FSpectrum.Info.Desc);
  end;
end;

procedure TPlotPanel.DrawTraces(const R: TRect; XMin, XMax, YMin, YMax: Double);
var
  I, J, X, Y, Alpha: Integer;
  Freqs, Levels: TArray<Double>;
  Sweep: TSweep;
  Col, BgCol: TColor;
  Sw: Integer;
  { 按 X 像素列做 min/max 抽稀用 }
  CurCol, ColMin, ColMax, LastX, LastY: Integer;
  HasCol, HasPrev: Boolean;
begin
  if (FSpectrum = nil) or (FSpectrum.Count = 0) then
    Exit;

  BgCol := FSettings.BackgroundColour;
  Sw := FSpectrum.Count;
  Canvas.Pen.Width := 1;

  for I := 0 to Sw - 1 do
  begin
    Sweep := FSpectrum[I];
    if not Sweep.Sorted(Freqs, Levels) then
      Continue;

    { 越靠近最新的扫描越亮 }
    Alpha := 60 + Round(195 * (I + 1) / Sw);
    Col := ColorBlend(FSettings.TraceColour, BgCol, Byte(Alpha));

    if I = Sw - 1 then
    begin
      Canvas.Pen.Width := 2;
      Canvas.Pen.Color := FSettings.TraceColour;
    end
    else
    begin
      Canvas.Pen.Width := 1;
      Canvas.Pen.Color := Col;
    end;

    { 每个 X 像素列只保留 min/max 两个顶点: GDI 调用量从"每点"降到"每列",
       与 NFFT 解耦; 高 NFFT 时不再因几十万次 LineTo 卡死 }
    HasCol := False;
    HasPrev := False;
    LastX := 0;
    LastY := 0;
    CurCol := 0;
    ColMin := 0;
    ColMax := 0;

    for J := 0 to High(Freqs) do
    begin
      if (Freqs[J] < XMin) or (Freqs[J] > XMax) then
        Continue;
      X := FreqToX(Freqs[J], XMin, XMax);
      Y := DbToY(LimitDouble(Levels[J], YMin, YMax), YMin, YMax);

      if (not HasCol) or (X <> CurCol) then
      begin
        if HasCol then
        begin
          { 输出上一列: 先到 min 再到 max, 形成包络 }
          Canvas.LineTo(CurCol, ColMin);
          if ColMax <> ColMin then
            Canvas.LineTo(CurCol, ColMax);
          HasPrev := True;
          LastX := CurCol;
          LastY := ColMax;
        end;
        HasCol := True;
        CurCol := X;
        ColMin := Y;
        ColMax := Y;
        if HasPrev then
          Canvas.MoveTo(LastX, LastY)
        else
          Canvas.MoveTo(X, Y);
      end
      else
      begin
        if Y < ColMin then
          ColMin := Y;
        if Y > ColMax then
          ColMax := Y;
      end;
    end;

    if HasCol then
    begin
      Canvas.LineTo(CurCol, ColMin);
      if ColMax <> ColMin then
        Canvas.LineTo(CurCol, ColMax);
    end;
  end;
  Canvas.Pen.Width := 1;
end;

function TPlotPanel.NearestIndex(const Freqs: TArray<Double>; Value: Double): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Result := 0;
  if Length(Freqs) = 0 then
    Exit;
  Lo := 0;
  Hi := High(Freqs);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if Freqs[Mid] < Value then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  Result := Lo;
  if (Lo > 0) and (Abs(Freqs[Lo - 1] - Value) < Abs(Freqs[Lo] - Value)) then
    Result := Lo - 1;
end;

procedure TPlotPanel.DrawPeaks(const R: TRect; XMin, XMax, YMin, YMax: Double);
var
  Sweep: TSweep;
  Freqs, Levels: TArray<Double>;
  I, X, Y: Integer;
  Threshold, MaxLevel: Double;
  Txt: string;
begin
  if not FShowPeaks or (FSpectrum = nil) or (FSpectrum.Count = 0) then
    Exit;

  Sweep := FSpectrum.Latest;
  if (Sweep = nil) or not Sweep.Sorted(Freqs, Levels) then
    Exit;

  MaxLevel := -MaxDouble;
  for I := 0 to High(Levels) do
    if Levels[I] > MaxLevel then
      MaxLevel := Levels[I];
  Threshold := MaxLevel - 12;

  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Size := 7;
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Color := FSettings.PeakColour;

  for I := 1 to High(Levels) - 1 do
  begin
    if Levels[I] < Threshold then
      Continue;
    if (Levels[I] <= Levels[I - 1]) or (Levels[I] <= Levels[I + 1]) then
      Continue;
    if (Freqs[I] < XMin) or (Freqs[I] > XMax) then
      Continue;

    X := FreqToX(Freqs[I], XMin, XMax);
    Y := DbToY(Levels[I], YMin, YMax);
    Canvas.MoveTo(X - 4, Y - 8);
    Canvas.LineTo(X + 4, Y - 8);
    Canvas.LineTo(X, Y - 2);
    Canvas.LineTo(X - 4, Y - 8);
    Canvas.Font.Color := FSettings.PeakColour;
    Txt := FormatFloat('0.000', Freqs[I]);
    Canvas.TextOut(X - Canvas.TextWidth(Txt) div 2, Y - 22, Txt);
  end;
end;

procedure TPlotPanel.DrawCursor(const R: TRect; XMin, XMax, YMin, YMax: Double);
var
  Sweep: TSweep;
  Freqs, Levels: TArray<Double>;
  Best, X, Y: Integer;
  Freq, BestDB: Double;
  Txt: string;
begin
  if not FMouseIn or (FSpectrum = nil) or (FSpectrum.Count = 0) then
    Exit;

  Sweep := FSpectrum.Latest;
  if (Sweep = nil) or not Sweep.Sorted(Freqs, Levels) then
    Exit;

  if not PtInRect(R, Point(FMouseX, FMouseY)) then
    Exit;

  Freq := XMin + (FMouseX - R.Left) / R.Width * (XMax - XMin);
  { Freqs 已按频率升序, 用二分找最近点, 避免每次鼠标移动做 O(N) 全扫 }
  Best := NearestIndex(Freqs, Freq);

  X := FreqToX(Freqs[Best], XMin, XMax);
  Y := DbToY(Levels[Best], YMin, YMax);
  BestDB := Levels[Best];

  Canvas.Pen.Color := $00FFFF80;
  Canvas.Pen.Style := psDot;
  Canvas.Pen.Width := 1;
  Canvas.MoveTo(X, R.Top);
  Canvas.LineTo(X, R.Bottom);
  Canvas.MoveTo(R.Left, Y);
  Canvas.LineTo(R.Right, Y);
  Canvas.Pen.Style := psSolid;

  Txt := Format('%.4f MHz  %.1f dB', [Freqs[Best], BestDB]);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := $00303030;
  Canvas.Font.Color := $00FFFF80;
  Canvas.Pen.Color := $00808080;
  Canvas.Rectangle(X + 8, Y - 26, X + 8 + Canvas.TextWidth(Txt) + 10, Y - 8);
  Canvas.TextOut(X + 13, Y - 23, Txt);
  Canvas.Brush.Style := bsClear;
end;

procedure TPlotPanel.Paint;
var
  XMin, XMax, YMin, YMax: Double;
begin
  inherited;
  FDataDirty := False;
  FLastPaint := GetTickCount;
  if FSettings = nil then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Exit;
  end;

  DrawBack;
  FDrawArea := Rect(64, 24, Width - 20, Height - 42);
  if (FDrawArea.Width < 20) or (FDrawArea.Height < 20) then
    Exit;

  CalcRange(XMin, XMax, YMin, YMax);
  DrawGrid(FDrawArea, XMin, XMax, YMin, YMax);
  DrawTraces(FDrawArea, XMin, XMax, YMin, YMax);
  DrawPeaks(FDrawArea, XMin, XMax, YMin, YMax);
  DrawCursor(FDrawArea, XMin, XMax, YMin, YMax);
end;

procedure TPlotPanel.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FMouseIn := True;
  FMouseX := X;
  FMouseY := Y;
  Redraw;
end;

end.
