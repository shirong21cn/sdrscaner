unit SdrMain;

{
  主窗口: 对应原工程 main_window.py (FrameMain) 的核心交互

  界面全部由代码构建(不依赖 .dfm), 便于命令行编译与版本管理。
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Math,
  System.Types, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.Menus,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Buttons,
  SdrTypes, SdrDevice, SdrEngine, SdrSpectrum, SdrSettings, SdrPlot;

type
  TFrameMain = class(TForm)
  private
    FSettings: TSdrSettings;
    FSpectrum: TSpectrumSet;
    FThread: TScanThread;
    FSource: TRtlSource;
    FPlot: TPlotPanel;
    FStatus: TStatusBar;
    FBar: TPanel;
    FMeasPanel: TPanel;
    FLblPeak, FLblAvg, FLblHbw, FLblObw: TLabel;
    FEdStart, FEdStop: TEdit;
    FEdYMin, FEdYMax: TEdit;
    FCbMode, FCbDwell, FCbNfft, FCbGain: TComboBox;
    FCbDevice: TComboBox;
    FBtnStart, FBtnStop: TButton;
    FDeviceInfos: TDeviceInfoArray;
    FUpdatingUi: Boolean;
    FCurrentFile: string;
    FLastMeasure: Cardinal;
    FScanning: Boolean;
    FLastScanError: string;

    function EnsureLibrary(out Err: string): Boolean;
    function EnsureDevice(out Err: string): Boolean;
    procedure BuildUi;
    procedure BuildMenu;
    procedure FillCombos;
    procedure RefreshDeviceList;
    procedure CbDeviceChange(Sender: TObject);
    procedure ActRefreshDevices(Sender: TObject);
    procedure UiToSettings;
    procedure SettingsToUi;
    procedure StartScan;
    procedure StopScan;
    procedure UpdateMeasure(Force: Boolean);
    procedure UpdateButtons;
    procedure SetStatus(const Txt: string; Panel: Integer = 0);

    procedure ScanLog(Sender: TObject; Ev: TScanEvent; const Msg: string);
    procedure ScanData(Sender: TObject; TimeStamp: Double;
      const Points: TPoint2DArray);
    procedure ScanProgress(Sender: TObject; FreqHz: Int64; Step, TotalSteps: Integer);

    procedure ActNew(Sender: TObject);
    procedure ActOpen(Sender: TObject);
    procedure ActSave(Sender: TObject);
    procedure ActSaveAs(Sender: TObject);
    procedure ActExportCsv(Sender: TObject);
    procedure ActExit(Sender: TObject);
    procedure ActStart(Sender: TObject);
    procedure ActStop(Sender: TObject);
    procedure ActAutoScale(Sender: TObject);
    procedure ActResetZoom(Sender: TObject);
    procedure ResetZoomToDefault;
    procedure ApplyDbRange;
    procedure EdDbRangeExit(Sender: TObject);
    procedure EdDbRangeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PlotRangeChanged(Sender: TObject);
    procedure ClearDisplay;
    procedure ActAbout(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure ReleaseDevice;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  FrameMain: TFrameMain;

implementation

const
  CL_BAR    = TColor($00F3F3F3);
  CL_TRACE  = TColor($00C8F0C8);
  { 单次扫描最多保留的频点数: 高 NFFT 时按步内等间隔抽稀到此上限,
    防止 TDictionary 键数(内存) 与绘制点数同时失控 }
  MAX_SWEEP_POINTS = 300000;

constructor TFrameMain.Create(AOwner: TComponent);
begin
  { 本窗体界面完全由代码构建, 没有 .dfm 资源, 因此必须走 CreateNew 跳过资源加载 }
  inherited CreateNew(AOwner);
  FSettings := TSdrSettings.Create;
  FSpectrum := TSpectrumSet.Create;
  FLastMeasure := 0;
  FScanning := False;
  FSettings.Load;
  OnClose := FormClose;
  BuildUi;
  BuildMenu;
  FillCombos;
  SettingsToUi;
  UpdateButtons;
end;

destructor TFrameMain.Destroy;
begin
  StopScan;
  ReleaseDevice;
  FSettings.Save;
  FSpectrum.Free;
  FSettings.Free;
  if GRtlLib <> nil then
  begin
    GRtlLib.Free;
    GRtlLib := nil;
  end;
  inherited;
end;

procedure TFrameMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  { 关闭窗口时先停线程, 再关闭设备句柄并释放 rtlsdr.dll,
    否则设备会一直被占用到进程完全结束, 下次打开报占用 }
  StopScan;
  ReleaseDevice;
end;

procedure TFrameMain.ReleaseDevice;
begin
  if FSource <> nil then
  begin
    FSource.Close;
    FreeAndNil(FSource);
  end;
end;

procedure TFrameMain.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  { 本窗体用 CreateNew 构建且 owner 为 VCL 的 TApplication 隐藏窗口,
    默认不会出现在任务栏; 强制 WS_EX_APPWINDOW 保证任务栏有运行图标 }
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
end;

{ ============================ 界面构建 ============================ }

procedure TFrameMain.BuildUi;
var
  L: TLabel;
  X: Integer;
begin
  Caption := APP_NAME + '  ' + APP_VER + '  -  老皮 QQ30922884';
  Width := 1200;
  Height := 780;
  Position := poScreenCenter;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  Color := CL_BAR;

  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  FStatus.Panels.Add;
  FStatus.Panels.Add;
  FStatus.Panels.Add;
  FStatus.Panels[0].Width := 520;
  FStatus.Panels[1].Width := 220;

  FMeasPanel := TPanel.Create(Self);
  FMeasPanel.Parent := Self;
  FMeasPanel.Align := alBottom;
  FMeasPanel.Height := 30;
  FMeasPanel.BevelOuter := bvNone;
  FMeasPanel.Color := CL_BAR;

  FLblPeak := TLabel.Create(Self);
  FLblPeak.Parent := FMeasPanel;
  FLblPeak.Left := 10;
  FLblPeak.Top := 7;
  FLblPeak.Caption := 'Peak: -';

  FLblAvg := TLabel.Create(Self);
  FLblAvg.Parent := FMeasPanel;
  FLblAvg.Left := 300;
  FLblAvg.Top := 7;
  FLblAvg.Caption := 'Avg: -';

  FLblHbw := TLabel.Create(Self);
  FLblHbw.Parent := FMeasPanel;
  FLblHbw.Left := 560;
  FLblHbw.Top := 7;
  FLblHbw.Caption := 'HBW: -';

  FLblObw := TLabel.Create(Self);
  FLblObw.Parent := FMeasPanel;
  FLblObw.Left := 830;
  FLblObw.Top := 7;
  FLblObw.Caption := 'OBW: -';

  { 电平上下限手动设定: 位于测量栏右侧, 回车或失焦即生效 }
  L := TLabel.Create(Self);
  L.Parent := FMeasPanel;
  L.Left := 900;
  L.Top := 7;
  L.Caption := 'Ymin';
  FEdYMin := TEdit.Create(Self);
  FEdYMin.Parent := FMeasPanel;
  FEdYMin.Left := 940;
  FEdYMin.Top := 4;
  FEdYMin.Width := 56;
  FEdYMin.Text := FormatFloat('0.0', FSettings.YMin);
  FEdYMin.OnExit := EdDbRangeExit;
  FEdYMin.OnKeyDown := EdDbRangeKeyDown;

  L := TLabel.Create(Self);
  L.Parent := FMeasPanel;
  L.Left := 1006;
  L.Top := 7;
  L.Caption := 'Ymax';
  FEdYMax := TEdit.Create(Self);
  FEdYMax.Parent := FMeasPanel;
  FEdYMax.Left := 1046;
  FEdYMax.Top := 4;
  FEdYMax.Width := 56;
  FEdYMax.Text := FormatFloat('0.0', FSettings.YMax);
  FEdYMax.OnExit := EdDbRangeExit;
  FEdYMax.OnKeyDown := EdDbRangeKeyDown;

  FBar := TPanel.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alTop;
  FBar.Height := 48;
  FBar.BevelOuter := bvNone;
  FBar.Color := CL_BAR;

  X := 10;
  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Device';
  FCbDevice := TComboBox.Create(Self);
  FCbDevice.Parent := FBar;
  FCbDevice.Left := X;
  FCbDevice.Top := 21;
  FCbDevice.Width := 210;
  FCbDevice.Style := csDropDownList;
  FCbDevice.DropDownWidth := 460;
  FCbDevice.OnChange := CbDeviceChange;
  Inc(X, 218);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Start (MHz)';
  FEdStart := TEdit.Create(Self);
  FEdStart.Parent := FBar;
  FEdStart.Left := X;
  FEdStart.Top := 22;
  FEdStart.Width := 82;
  Inc(X, 90);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Stop (MHz)';
  FEdStop := TEdit.Create(Self);
  FEdStop.Parent := FBar;
  FEdStop.Left := X;
  FEdStop.Top := 22;
  FEdStop.Width := 82;
  Inc(X, 90);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Mode';
  FCbMode := TComboBox.Create(Self);
  FCbMode.Parent := FBar;
  FCbMode.Left := X;
  FCbMode.Top := 21;
  FCbMode.Width := 100;
  FCbMode.Style := csDropDownList;
  Inc(X, 108);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Dwell';
  FCbDwell := TComboBox.Create(Self);
  FCbDwell.Parent := FBar;
  FCbDwell.Left := X;
  FCbDwell.Top := 21;
  FCbDwell.Width := 80;
  FCbDwell.Style := csDropDownList;
  Inc(X, 88);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'FFT';
  FCbNfft := TComboBox.Create(Self);
  FCbNfft.Parent := FBar;
  FCbNfft.Left := X;
  FCbNfft.Top := 21;
  FCbNfft.Width := 70;
  FCbNfft.Style := csDropDownList;
  Inc(X, 78);

  L := TLabel.Create(Self);
  L.Parent := FBar;
  L.Left := X;
  L.Top := 5;
  L.Caption := 'Gain (dB)';
  FCbGain := TComboBox.Create(Self);
  FCbGain.Parent := FBar;
  FCbGain.Left := X;
  FCbGain.Top := 21;
  FCbGain.Width := 86;
  FCbGain.Style := csDropDownList;
  Inc(X, 96);

  FBtnStart := TButton.Create(Self);
  FBtnStart.Parent := FBar;
  FBtnStart.Left := X;
  FBtnStart.Top := 18;
  FBtnStart.Width := 92;
  FBtnStart.Height := 26;
  FBtnStart.Caption := 'Start';
  FBtnStart.OnClick := ActStart;
  Inc(X, 100);

  FBtnStop := TButton.Create(Self);
  FBtnStop.Parent := FBar;
  FBtnStop.Left := X;
  FBtnStop.Top := 18;
  FBtnStop.Width := 92;
  FBtnStop.Height := 26;
  FBtnStop.Caption := 'Stop';
  FBtnStop.OnClick := ActStop;

  FPlot := TPlotPanel.Create(Self);
  FPlot.Parent := Self;
  FPlot.Align := alClient;
  FPlot.Settings := FSettings;
  FPlot.Spectrum := FSpectrum;
  FPlot.OnRangeChanged := PlotRangeChanged;
end;

procedure TFrameMain.BuildMenu;
var
  Main: TMainMenu;
  Root: TMenuItem;

  function AddItem(Parent: TMenuItem; const Caption: string; Handler: TNotifyEvent;
    ShortCut: TShortCut = 0): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := Caption;
    Result.OnClick := Handler;
    if ShortCut <> 0 then
      Result.ShortCut := ShortCut;
    Parent.Add(Result);
  end;

begin
  Main := TMainMenu.Create(Self);
  Menu := Main;

  Root := TMenuItem.Create(Self);
  Root.Caption := '&File';
  Main.Items.Add(Root);
  AddItem(Root, '&New', ActNew, ShortCut(Ord('N'), [ssCtrl]));
  AddItem(Root, '&Open...', ActOpen, ShortCut(Ord('O'), [ssCtrl]));
  AddItem(Root, '&Save', ActSave, ShortCut(Ord('S'), [ssCtrl]));
  AddItem(Root, 'Save &As...', ActSaveAs);
  AddItem(Root, 'Export &CSV...', ActExportCsv);
  AddItem(Root, '-', nil);
  AddItem(Root, 'E&xit', ActExit);

  Root := TMenuItem.Create(Self);
  Root.Caption := '&Scan';
  Main.Items.Add(Root);
  AddItem(Root, '&Start', ActStart, ShortCut(VK_F5, []));
  AddItem(Root, 'S&top', ActStop, ShortCut(VK_F6, []));
  AddItem(Root, '-', nil);
  AddItem(Root, 'Refresh De&vices', ActRefreshDevices);

  Root := TMenuItem.Create(Self);
  Root.Caption := '&View';
  Main.Items.Add(Root);
  AddItem(Root, '&Auto Scale', ActAutoScale);
  AddItem(Root, '&Reset Zoom', ActResetZoom);

  Root := TMenuItem.Create(Self);
  Root.Caption := '&Help';
  Main.Items.Add(Root);
  AddItem(Root, '&About', ActAbout);
end;

procedure TFrameMain.FillCombos;
var
  I: Integer;
  G: Double;
begin
  FCbMode.Items.Add('Single');
  FCbMode.Items.Add('Continuous');

  for I := 0 to DWELL_COUNT - 1 do
    FCbDwell.Items.Add(DWELL_TEXT[I]);

  for I := 0 to NFFT_COUNT - 1 do
    FCbNfft.Items.Add(IntToStr(NFFT_VALUES[I]));

  FCbGain.Items.Add('Auto');
  G := 0.0;
  while G <= 49.6 + 1.0E-6 do
  begin
    FCbGain.Items.Add(FormatFloat('0.0', G));
    G := G + 2.4;
  end;

  RefreshDeviceList;
end;

{ 枚举本机 RTL-SDR 设备并刷新设备下拉框(多设备时可显式选择, 不再固定使用设备 0) }
procedure TFrameMain.RefreshDeviceList;
var
  Err: string;
  I: Integer;
  S: string;
begin
  if FCbDevice = nil then
    Exit;

  FUpdatingUi := True;
  try
    FCbDevice.Items.BeginUpdate;
    try
      FCbDevice.Items.Clear;
      FDeviceInfos := nil;

      if EnsureLibrary(Err) then
        FDeviceInfos := EnumerateRtlDevices(GRtlLib);

      if Length(FDeviceInfos) = 0 then
      begin
        if Err <> '' then
          FCbDevice.Items.Add('(rtlsdr.dll 加载失败)')
        else
          FCbDevice.Items.Add('(未检测到 RTL-SDR 设备)');
        FCbDevice.ItemIndex := 0;
        FCbDevice.Enabled := False;
      end
      else
      begin
        for I := 0 to High(FDeviceInfos) do
        begin
          S := Format('%d: %s', [FDeviceInfos[I].Index, FDeviceInfos[I].Name]);
          if FDeviceInfos[I].Serial <> '' then
            S := S + ' [' + FDeviceInfos[I].Serial + ']';
          FCbDevice.Items.Add(S);
        end;
        FCbDevice.Enabled := True;
        FSettings.IndexRtl := LimitInt(FSettings.IndexRtl, 0, High(FDeviceInfos));
        FCbDevice.ItemIndex := FSettings.IndexRtl;
      end;
    finally
      FCbDevice.Items.EndUpdate;
    end;
  finally
    FUpdatingUi := False;
  end;
end;

{ 用户切换设备: 停止状态下立即释放旧设备, 下次扫描用新设备 }
procedure TFrameMain.CbDeviceChange(Sender: TObject);
var
  Idx: Integer;
begin
  if FUpdatingUi then
    Exit;
  Idx := FCbDevice.ItemIndex;
  if (Idx < 0) or (Idx > High(FDeviceInfos)) then
    Exit;
  if Idx = FSettings.IndexRtl then
    Exit;

  if FScanning then
  begin
    FUpdatingUi := True;
    try
      FCbDevice.ItemIndex := FSettings.IndexRtl;
    finally
      FUpdatingUi := False;
    end;
    ShowMessage('正在扫描, 请先停止扫描再切换设备。');
    Exit;
  end;

  FreeAndNil(FSource);
  FSettings.IndexRtl := Idx;
  SetStatus(Format('已选择设备 %d: %s', [Idx, FDeviceInfos[Idx].Name]), 1);
end;

procedure TFrameMain.ActRefreshDevices(Sender: TObject);
begin
  RefreshDeviceList;
  if Length(FDeviceInfos) = 0 then
    SetStatus('未检测到 RTL-SDR 设备', 1)
  else
    SetStatus(Format('检测到 %d 个设备', [Length(FDeviceInfos)]), 1);
end;

procedure TFrameMain.SettingsToUi;
var
  I, Idx: Integer;
begin
  FEdStart.Text := FormatFloat('0.000', FSettings.StartMHz);
  FEdStop.Text := FormatFloat('0.000', FSettings.StopMHz);
  if FEdYMin <> nil then
    FEdYMin.Text := FormatFloat('0.0', FSettings.YMin);
  if FEdYMax <> nil then
    FEdYMax.Text := FormatFloat('0.0', FSettings.YMax);

  if (FCbDevice <> nil) and FCbDevice.Enabled then
  begin
    FUpdatingUi := True;
    try
      if (FSettings.IndexRtl >= 0) and (FSettings.IndexRtl <= High(FDeviceInfos)) then
        FCbDevice.ItemIndex := FSettings.IndexRtl;
    finally
      FUpdatingUi := False;
    end;
  end;

  if FSettings.Mode = smSingle then
    FCbMode.ItemIndex := 0
  else
    FCbMode.ItemIndex := 1;

  Idx := 0;
  for I := 0 to DWELL_COUNT - 1 do
    if Abs(DWELL_VALUE[I] - FSettings.Dwell) < 1.0E-6 then
      Idx := I;
  FCbDwell.ItemIndex := Idx;

  Idx := 0;
  for I := 0 to NFFT_COUNT - 1 do
    if NFFT_VALUES[I] = FSettings.NFFT then
      Idx := I;
  FCbNfft.ItemIndex := Idx;

  if not FSettings.GainMode then
    FCbGain.ItemIndex := 0
  else
  begin
    Idx := 0;
    for I := 1 to FCbGain.Items.Count - 1 do
      if Abs(StrToFloatDef(FCbGain.Items[I], 0) - FSettings.Gain) < 0.05 then
        Idx := I;
    FCbGain.ItemIndex := Idx;
  end;
end;

procedure TFrameMain.UiToSettings;
begin
  FSettings.StartMHz := StrToFloatDef(FEdStart.Text, FSettings.StartMHz);
  FSettings.StopMHz := StrToFloatDef(FEdStop.Text, FSettings.StopMHz);
  if FSettings.StopMHz <= FSettings.StartMHz then
    FSettings.StopMHz := FSettings.StartMHz + 1;

  { 设备选择: 下拉框索引即 rtlsdr 设备序号 }
  if (FCbDevice <> nil) and FCbDevice.Enabled and (FCbDevice.ItemIndex >= 0) and
     (FCbDevice.ItemIndex <= High(FDeviceInfos)) then
  begin
    FSettings.IndexRtl := FCbDevice.ItemIndex;
  end;

  if FCbMode.ItemIndex = 1 then
    FSettings.Mode := smContinuous
  else
    FSettings.Mode := smSingle;

  if (FCbDwell.ItemIndex >= 0) and (FCbDwell.ItemIndex < DWELL_COUNT) then
    FSettings.Dwell := DWELL_VALUE[FCbDwell.ItemIndex];

  if (FCbNfft.ItemIndex >= 0) and (FCbNfft.ItemIndex < NFFT_COUNT) then
    FSettings.NFFT := NFFT_VALUES[FCbNfft.ItemIndex];

  if FCbGain.ItemIndex <= 0 then
  begin
    FSettings.GainMode := False;
    FSettings.Gain := 0;
  end
  else
  begin
    FSettings.GainMode := True;
    FSettings.Gain := StrToFloatDef(FCbGain.Items[FCbGain.ItemIndex], 0);
  end;

  { 电平上下限: 以界面手动输入为准, 非法则退回 -100..0 }
  if (FEdYMin <> nil) and (FEdYMax <> nil) then
  begin
    FSettings.YMin := StrToFloatDef(FEdYMin.Text, FSettings.YMin);
    FSettings.YMax := StrToFloatDef(FEdYMax.Text, FSettings.YMax);
    if FSettings.YMax <= FSettings.YMin then
    begin
      FSettings.YMin := -100;
      FSettings.YMax := 0;
    end;
  end;

  FPlot.Redraw;
end;

{ ============================ 设备 ============================ }

function TFrameMain.EnsureLibrary(out Err: string): Boolean;
begin
  Err := '';
  if GRtlLib = nil then
    GRtlLib := TRtlSdrLib.Create;
  if GRtlLib.Loaded then
    Exit(True);
  Result := GRtlLib.Load('', Err);
end;

function TFrameMain.EnsureDevice(out Err: string): Boolean;
var
  Rtl: TRtlDevice;
  Infos: TDeviceInfoArray;
  FirstErr: string;
  OldIdx: Integer;
  I: Integer;
begin
  Result := False;
  Err := '';
  if FSource <> nil then
  begin
    if FSource.IsOpen then
      Exit(True);
    { 句柄已被关闭: 释放后重新打开, 否则会一直返回失败 }
    FreeAndNil(FSource);
  end;

  if not EnsureLibrary(Err) then
  begin
    Err := 'rtlsdr.dll 加载失败: ' + Err + sLineBreak +
      '请将 rtlsdr.dll (及 libusb-1.0.dll) 放到程序目录。';
    Exit;
  end;

  begin
    { 优先用设备下拉框缓存的枚举结果; 若为空则重新枚举 }
    if Length(FDeviceInfos) = 0 then
      FDeviceInfos := EnumerateRtlDevices(GRtlLib);
    Infos := FDeviceInfos;
    if Length(Infos) = 0 then
    begin
      Err := '未检测到 RTL-SDR 设备';
      Exit;
    end;
    FSettings.IndexRtl := LimitInt(FSettings.IndexRtl, 0, High(Infos));
    if (FCbDevice <> nil) and FCbDevice.Enabled and
       (FCbDevice.ItemIndex <> FSettings.IndexRtl) then
    begin
      FUpdatingUi := True;
      try
        FCbDevice.ItemIndex := FSettings.IndexRtl;
      finally
        FUpdatingUi := False;
      end;
    end;
    Rtl := TRtlDevice.Create(GRtlLib);
    if not Rtl.Open(FSettings.IndexRtl, Err) then
    begin
      { 首选序号打不开(常见于枚举出的僵尸条目)时, 自动回退到其它可打开的设备 }
      FirstErr := Err;
      OldIdx := FSettings.IndexRtl;
      Rtl.Free;
      Rtl := nil;
      for I := 0 to High(Infos) do
        if I <> FSettings.IndexRtl then
        begin
          Rtl := TRtlDevice.Create(GRtlLib);
          if Rtl.Open(I, Err) then
          begin
            FSettings.IndexRtl := I;
            Break;
          end;
          Rtl.Free;
          Rtl := nil;
        end;

      if Rtl = nil then
      begin
        Err := Format('无法打开设备 %d (%s)。' + sLineBreak +
          '该设备可能已被其它程序占用, 或已被拔出。' + sLineBreak + '底层错误: %s',
          [FSettings.IndexRtl, Infos[FSettings.IndexRtl].Name, FirstErr]);
        RefreshDeviceList;
        Exit;
      end;

      { 已切换到其它设备, 同步设备下拉框 }
      if (FCbDevice <> nil) and FCbDevice.Enabled and
         (FCbDevice.ItemIndex <> FSettings.IndexRtl) then
      begin
        FUpdatingUi := True;
        try
          FCbDevice.ItemIndex := FSettings.IndexRtl;
        finally
          FUpdatingUi := False;
        end;
      end;
      SetStatus(Format('设备 %d 打不开, 已自动切换到 %d (%s)',
        [OldIdx, FSettings.IndexRtl, FirstErr]), 1);
    end;
    FSource := Rtl;
    SetStatus(Format('设备: [%d] %s  (%s)',
      [FSettings.IndexRtl, Infos[FSettings.IndexRtl].Name, TunerName(Rtl.GetTunerType)]), 1);
  end;

  Result := True;
end;

{ ============================ 扫描控制 ============================ }

procedure TFrameMain.StartScan;
var
  Err: string;
begin
  if FScanning then
    Exit;

  UiToSettings;

  if (FSettings.StartMHz < F_MIN) or (FSettings.StopMHz > F_MAX) then
  begin
    ShowMessage(Format('频率范围需在 %d - %d MHz 之间', [F_MIN, F_MAX]));
    Exit;
  end;

  if not EnsureDevice(Err) then
  begin
    ShowMessage(Err);
    Exit;
  end;

  { 每次开始扫描: 先清屏(清空上一次扫描数据与测量值), 再按当前上下限复位缩放 }
  ClearDisplay;
  ResetZoomToDefault;

  FThread := TScanThread.Create(FSource, FSettings);
  FThread.OnLog := ScanLog;
  FThread.OnData := ScanData;
  FThread.OnProgress := ScanProgress;
  FScanning := True;
  UpdateButtons;
  SetStatus('扫描中...', 0);
  FThread.Start;
end;

procedure TFrameMain.StopScan;
begin
  if FThread <> nil then
  begin
    FThread.StopScan;
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
  FScanning := False;
  UpdateButtons;
end;

procedure TFrameMain.UpdateButtons;
begin
  FBtnStart.Enabled := not FScanning;
  FBtnStop.Enabled := FScanning;
  FEdStart.Enabled := not FScanning;
  FEdStop.Enabled := not FScanning;
  FCbMode.Enabled := not FScanning;
end;

procedure TFrameMain.SetStatus(const Txt: string; Panel: Integer);
begin
  if (Panel >= 0) and (Panel < FStatus.Panels.Count) then
    FStatus.Panels[Panel].Text := Txt;
end;

procedure TFrameMain.ScanLog(Sender: TObject; Ev: TScanEvent; const Msg: string);
begin
  case Ev of
    seStarting:
      begin
        FLastScanError := '';
        SetStatus(Msg, 0);
      end;
    seInfo:
      SetStatus(Msg, 0);
    seError:
      begin
        FLastScanError := Msg;
        SetStatus('错误: ' + Msg, 0);
        { 不能在此复位扫描状态: 引擎出错后会结束线程并补发 seFinished,
          提前复位会让界面误以为已停止, 用户重复启动会并发两个线程抢同一设备 }
      end;
    seFinished:
      begin
        { 结束状态不能覆盖错误信息, 否则用户只看到"扫描完成"却无结果 }
        if FLastScanError = '' then
          SetStatus(Msg, 0)
        else
          SetStatus('扫描结束, 但发生错误: ' + FLastScanError, 0);
        FScanning := False;
        UpdateButtons;
      end;
  end;
end;

procedure TFrameMain.ScanData(Sender: TObject; TimeStamp: Double;
  const Points: TPoint2DArray);
var
  I, J, K, Stride, PerStep, Total, BestIdx, SelCount: Integer;
  BestLvl: Double;
  Sel: TPoint2DArray;
begin
  if Length(Points) = 0 then
    Exit;

  { 高 NFFT 时每步点数可达 16385, 单次扫描累积点数会到百万级,
    字典与重绘全部雪崩。按步内分段抽稀, 把单次扫描总点数封顶;
    每段取段内最高电平, 保证窄带峰不会被抽掉。 }
  Total := 1;
  if FThread <> nil then
    Total := FThread.TotalSteps;
  if Total < 1 then
    Total := 1;
  PerStep := Length(Points);
  Stride := 1;
  while (Int64(Total) * ((PerStep + Stride - 1) div Stride)) > MAX_SWEEP_POINTS do
    Inc(Stride);

  if Stride = 1 then
    FSpectrum.AddPoints(TimeStamp, Points, True)
  else
  begin
    { 先抽稀到临时数组, 再一次性写入同一 sweep }
    SetLength(Sel, (Length(Points) + Stride - 1) div Stride);
    SelCount := 0;
    J := 0;
    while J <= High(Points) do
    begin
      K := J + Stride - 1;
      if K > High(Points) then
        K := High(Points);
      BestIdx := J;
      BestLvl := Points[J].Y;
      for I := J + 1 to K do
        if Points[I].Y > BestLvl then
        begin
          BestLvl := Points[I].Y;
          BestIdx := I;
        end;
      Sel[SelCount] := Points[BestIdx];
      Inc(SelCount);
      J := K + 1;
    end;
    SetLength(Sel, SelCount);
    FSpectrum.AddPoints(TimeStamp, Sel, True);
  end;

  if FSpectrum.Count > FSettings.MaxSweeps then
    FSpectrum.RemoveOlder(FSettings.MaxSweeps);

  FPlot.Redraw;
  UpdateMeasure(False);
end;

procedure TFrameMain.ScanProgress(Sender: TObject; FreqHz: Int64; Step,
  TotalSteps: Integer);
begin
  if TotalSteps > 0 then
    SetStatus(Format('扫描 %.3f MHz  (%d/%d)', [FreqHz / 1.0E6, Step, TotalSteps]), 0);
end;

procedure TFrameMain.UpdateMeasure(Force: Boolean);
var
  Sweep: TSweep;
  M: TMeasureResult;
  Now_ : Cardinal;
begin
  Now_ := GetTickCount;
  if not Force and (Now_ - FLastMeasure < 250) then
    Exit;
  FLastMeasure := Now_;

  Sweep := FSpectrum.Latest;
  M := MeasureSweep(Sweep, FSettings.StartMHz, FSettings.StopMHz);
  if not M.Valid then
  begin
    FLblPeak.Caption := 'Peak: -';
    FLblAvg.Caption := 'Avg: -';
    FLblHbw.Caption := 'HBW: -';
    FLblObw.Caption := 'OBW: -';
    Exit;
  end;

  FLblPeak.Caption := Format('Peak: %.4f MHz  %.1f dB',
    [M.PeakFreq, M.PeakLevel]);
  FLblAvg.Caption := Format('Avg: %.1f dB   Flatness: %.2f',
    [M.AvgLevel, M.Flatness]);
  FLblHbw.Caption := Format('-3dB: %.4f MHz (%.1f kHz)',
    [M.HbwEnd - M.HbwStart, (M.HbwEnd - M.HbwStart) * 1000]);
  FLblObw.Caption := Format('OBW: %.4f MHz',
    [M.ObwEnd - M.ObwStart]);
end;

{ ============================ 菜单动作 ============================ }

procedure TFrameMain.ActNew(Sender: TObject);
begin
  ClearDisplay;
  FCurrentFile := '';
  ResetZoomToDefault;
  SetStatus('已新建', 0);
end;

procedure TFrameMain.ActOpen(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Filter := 'Delphi 版频谱 (*.rfsx)|*.rfsx|原版 rfs (*.rfs)|*.rfs';
    if not Dlg.Execute then
      Exit;
    if LowerCase(ExtractFileExt(Dlg.FileName)) = '.rfs' then
    begin
      ShowMessage('原版 .rfs 为 Python cPickle 二进制格式, 本程序无法直接读取。' + sLineBreak +
        '建议在原程序中导出为 CSV 后导入, 或使用 rfsx 格式。');
      Exit;
    end;
    FSpectrum.LoadFromFile(Dlg.FileName);
    FCurrentFile := Dlg.FileName;
    FPlot.Redraw;
    UpdateMeasure(True);
    SetStatus(Format('已打开 %s (%d 条扫描)',
      [ExtractFileName(Dlg.FileName), FSpectrum.Count]), 0);
  finally
    Dlg.Free;
  end;
end;

procedure TFrameMain.ActSave(Sender: TObject);
begin
  if FCurrentFile = '' then
    ActSaveAs(Sender)
  else
  begin
    FSpectrum.Info.StartMHz := FSettings.StartMHz;
    FSpectrum.Info.StopMHz := FSettings.StopMHz;
    FSpectrum.Info.Dwell := FSettings.Dwell;
    FSpectrum.Info.NFFT := FSettings.NFFT;
    FSpectrum.Info.Gain := FSettings.Gain;
    FSpectrum.Info.Lo := FSettings.Lo;
    FSpectrum.Info.Calibration := FSettings.Calibration;
    FSpectrum.SaveToFile(FCurrentFile);
    SetStatus('已保存 ' + ExtractFileName(FCurrentFile), 0);
  end;
end;

procedure TFrameMain.ActSaveAs(Sender: TObject);
var
  Dlg: TSaveDialog;
begin
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Filter := 'Delphi 版频谱 (*.rfsx)|*.rfsx';
    Dlg.DefaultExt := 'rfsx';
    if not Dlg.Execute then
      Exit;
    FCurrentFile := Dlg.FileName;
    ActSave(Sender);
  finally
    Dlg.Free;
  end;
end;

procedure TFrameMain.ActExportCsv(Sender: TObject);
var
  Dlg: TSaveDialog;
begin
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Filter := 'CSV (*.csv)|*.csv';
    Dlg.DefaultExt := 'csv';
    if not Dlg.Execute then
      Exit;
    FSpectrum.ExportCSV(Dlg.FileName);
    SetStatus('已导出 ' + ExtractFileName(Dlg.FileName), 0);
  finally
    Dlg.Free;
  end;
end;

procedure TFrameMain.ActExit(Sender: TObject);
begin
  Close;
end;

procedure TFrameMain.ActStart(Sender: TObject);
begin
  StartScan;
end;

procedure TFrameMain.ActStop(Sender: TObject);
begin
  StopScan;
  SetStatus('已停止', 0);
end;

procedure TFrameMain.ActAutoScale(Sender: TObject);
begin
  FSettings.AutoF := True;
  FSettings.AutoL := True;
  FPlot.Redraw;
end;

procedure TFrameMain.ClearDisplay;
begin
  FSpectrum.Clear;
  FLastMeasure := 0;
  FLblPeak.Caption := 'Peak: -';
  FLblAvg.Caption := 'Avg: -';
  FLblHbw.Caption := 'HBW: -';
  FLblObw.Caption := 'OBW: -';
end;

procedure TFrameMain.PlotRangeChanged(Sender: TObject);
begin
  if FUpdatingUi then
    Exit;
  { 自动量程回写后刷新输入框; 正在编辑时不覆盖用户输入 }
  if (FEdYMin <> nil) and not FEdYMin.Focused then
    FEdYMin.Text := FormatFloat('0.0', FSettings.YMin);
  if (FEdYMax <> nil) and not FEdYMax.Focused then
    FEdYMax.Text := FormatFloat('0.0', FSettings.YMax);
end;

procedure TFrameMain.ApplyDbRange;
var
  YMinV, YMaxV: Double;
begin
  if (FEdYMin = nil) or (FEdYMax = nil) then
    Exit;
  YMinV := StrToFloatDef(FEdYMin.Text, FSettings.YMin);
  YMaxV := StrToFloatDef(FEdYMax.Text, FSettings.YMax);
  if YMaxV <= YMinV then
  begin
    YMaxV := YMinV + 10;
  end;
  FSettings.AutoL := False;
  FSettings.YMin := YMinV;
  FSettings.YMax := YMaxV;
  FEdYMin.Text := FormatFloat('0.0', YMinV);
  FEdYMax.Text := FormatFloat('0.0', YMaxV);
  FPlot.Redraw;
end;

procedure TFrameMain.EdDbRangeExit(Sender: TObject);
begin
  ApplyDbRange;
end;

procedure TFrameMain.EdDbRangeKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    ApplyDbRange;
  end;
end;

procedure TFrameMain.ResetZoomToDefault;
var
  YMinV, YMaxV: Double;
begin
  { 默认电平范围 -100..0 dB; 界面已手动设定时沿用手动值 }
  YMinV := -100;
  YMaxV := 0;
  if (FEdYMin <> nil) and (FEdYMax <> nil) then
  begin
    YMinV := StrToFloatDef(FEdYMin.Text, YMinV);
    YMaxV := StrToFloatDef(FEdYMax.Text, YMaxV);
  end;
  if YMaxV <= YMinV then
  begin
    YMinV := -100;
    YMaxV := 0;
  end;
  FSettings.AutoF := False;
  FSettings.AutoL := False;
  FSettings.YMin := YMinV;
  FSettings.YMax := YMaxV;
  if (FEdYMin <> nil) and (FEdYMax <> nil) then
  begin
    FEdYMin.Text := FormatFloat('0.0', YMinV);
    FEdYMax.Text := FormatFloat('0.0', YMaxV);
  end;
  FPlot.Redraw;
end;

procedure TFrameMain.ActResetZoom(Sender: TObject);
begin
  ResetZoomToDefault;
end;

procedure TFrameMain.ActAbout(Sender: TObject);
begin
  ShowMessage(APP_NAME + ' ' + APP_VER + sLineBreak + sLineBreak +
    'Delphi 12 移植版 (基于 RTLSDR-Scanner v1.0)' + sLineBreak +
    'FFT/PSD: 自研基2 FFT + Welch 平均' + sLineBreak +
    '设备: 本地 RTLSDR (rtlsdr.dll)' + sLineBreak + sLineBreak +
    '作者: 老皮' + sLineBreak +
    'QQ: 30922884' + sLineBreak +
    '主页: www.2pascal.com' + sLineBreak +
    'GitHub: github.com/shirong21cn');
end;

end.
