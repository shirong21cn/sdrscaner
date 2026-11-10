program RtlSdrScanner;

{
  RTLSDR Scanner - Delphi 12 移植版
  基于 Python 原版 RTLSDR-Scanner v1.0.21959 重写

  作者: 老皮
  QQ: 30922884
  主页: www.2pascal.com
  GitHub: github.com/shirong21cn

  模块对应关系:
    SdrTypes.pas    <- constants.py, misc.py
    SdrDevice.pas   <- devices.py, rtltcp.py, pyrtlsdr 绑定
    SdrDsp.pas      <- matplotlib.mlab.psd, spectrum.py
    SdrSpectrum.pas <- spectrum.py (Extent/Measure), file.py (存取)
    SdrSettings.pas <- settings.py
    SdrEngine.pas   <- scan.py (ThreadScan)
    SdrPlot.pas     <- plot_spect.py (二维绘制)
    SdrMain.pas     <- main_window.py (FrameMain)
}

uses
  Vcl.Forms,
  SdrTypes in 'src\SdrTypes.pas',
  SdrDevice in 'src\SdrDevice.pas',
  SdrDsp in 'src\SdrDsp.pas',
  SdrSpectrum in 'src\SdrSpectrum.pas',
  SdrSettings in 'src\SdrSettings.pas',
  SdrEngine in 'src\SdrEngine.pas',
  SdrPlot in 'src\SdrPlot.pas',
  SdrMain in 'src\SdrMain.pas';

// 版本信息 / 作者信息资源 (由 tools\mkver.py 生成; brcc32 对中文和字符串长度处理有误)
{$R 'RtlSdrScanner.res'}

// 若需要程序图标, 在资源中加入 ICON 后重新生成 .res

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'RTLSDR Scanner';
  Application.CreateForm(TFrameMain, FrameMain);
  Application.Run;
end.
