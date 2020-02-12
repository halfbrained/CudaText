program cudatext;

{$mode objfpc}{$H+}

uses
  //heaptrc,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  SysUtils,
  Forms, lazcontrols, uniqueinstance_package, FormMain, FormConsole, proc_str,
  proc_py, proc_py_const, proc_globdata, FormFrame, form_menu_commands,
  formgoto, proc_cmd, form_menu_list, formsavetabs, formconfirmrep,
  formlexerprop, formlexerlib, proc_msg, proc_install_zip, formcolorsetup,
  formabout, formkeys, formcharmaps, proc_keysdialog,
  proc_customdialog, proc_miscutils, formlexerstyle,
  formlexerstylemap, formkeyinput, proc_scrollbars, proc_keymap_undolist,
  proc_customdialog_dummy, form_addon_report, fix_focus_window,
  formconfirmbinary, proc_lexer_styles, form_choose_theme, proc_appvariant;

{$R *.res}

begin
  NTickInitial:= GetTickCount64;
  {$IFDEF WINDOWS}
  if not AppAlwaysNewInstance then
    if IsAnotherInstanceRunning then Exit;
  if Screen.MonitorCount>1 then
    Application.MainFormOnTaskBar:= True;
  {$IFEND}
  Application.Title:= 'CudaText';
  Application.Scaled:= false;
  RequireDerivedFormResource:= True;
  Application.Initialize;
  Application.CreateForm(TfmMain, fmMain);
  Application.Run;
end.

