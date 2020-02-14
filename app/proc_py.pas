(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

Copyright (c) Alexey Torgashin
*)
unit proc_py;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  PythonEngine,
  proc_str,
  proc_globdata,
  proc_appvariant;

type
  { TAppPython }

  TAppPython = class
  private
    const NamePrefix = 'xx'; //the same as in py/cudatext_reset_plugins.py
  private
    FInited: boolean;
    FEngine: TPythonEngine;
    FRunning: boolean;
    FLastCommandModule: string;
    FLastCommandMethod: string;
    FLastCommandParam: TAppVariant;
    EventTime: QWord;
    EventTimes: TStringList;
    LoadedLocals: TStringList;
    LoadedModules: TStringList;
    ModuleMain: PPyObject;
    ModuleCud: PPyObject;
    GlobalsMain: PPyObject;
    GlobalsCud: PPyObject;
    procedure InitModuleMain;
    procedure InitModuleCud;
    procedure ImportCommand(const AObject, AModule: string);
    function ImportModuleCached(const AModule: string): PPyObject;
    function IsLoadedLocal(const S: string): boolean;
    function MethodEvalEx(const AObject, AMethod: string; const AParams: array of PPyObject): TAppPyEventResult;
    function MethodEvalObjects(const AObject, AFunc: string; const AParams: array of PPyObject): PPyObject;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Initialize;
    property Inited: boolean read FInited;
    property Engine: TPythonEngine read FEngine;
    property IsRunning: boolean read FRunning;
    property LastCommandModule: string read FLastCommandModule;
    property LastCommandMethod: string read FLastCommandMethod;
    property LastCommandParam: TAppVariant read FLastCommandParam;

    function Eval(const Command: string; UseFileMode: boolean=false): PPyObject;
    procedure Exec(const Command: string);

    function RunCommand(const AModule, AMethod: string;
      const AParams: TAppVariantArray): boolean;
    function RunEvent(const AModule, ACmd: string; AEd: TObject;
      const AParams: TAppVariantArray; ALazy: boolean): TAppPyEventResult;

    function RunModuleFunction(const AModule, AFunc: string;
      const AParams: array of PPyObject;
      const AParamNames: array of string): PPyObject;
    function RunModuleFunction(const AModule, AFunc: string;
      const AParams: array of PPyObject): PPyObject;

    function ValueFromString(const S: string): PPyObject;
    function ValueToString(Obj: PPyObject; QuoteStrings: boolean): string;

    procedure SetPath(const Dirs: array of string; DoAdd: boolean);
    procedure ClearCache;
    procedure DisableTiming;
    function GetTimingReport: string;
  end;

var
  AppPython: TAppPython;

implementation

{ TAppPython }

constructor TAppPython.Create;
begin
  inherited Create;
  LoadedLocals:= TStringList.Create;
  LoadedModules:= TStringList.Create;
  EventTimes:= TStringList.Create;
end;

destructor TAppPython.Destroy;
begin
  if Assigned(EventTimes) then
    FreeAndNil(EventTimes);
  FreeAndNil(LoadedModules);
  FreeAndNil(LoadedLocals);
  inherited Destroy;
end;

procedure TAppPython.Initialize;
begin
  FInited:= PythonOK;
  if FInited then
    FEngine:= GetPythonEngine;
end;

function TAppPython.IsLoadedLocal(const S: string): boolean; inline;
begin
  Result:= LoadedLocals.IndexOf(S)>=0;
end;

procedure TAppPython.DisableTiming;
begin
  FreeAndNil(EventTimes);
end;

function TAppPython.GetTimingReport: string;
var
  i: integer;
  tick: PtrInt;
begin
  Result:= IntToStr(EventTime div 10 * 10)+'ms (';
  for i:= 0 to EventTimes.Count-1 do
  begin
    tick:= PtrInt(EventTimes.Objects[i]);
    if i>0 then
      Result+= ', ';
    Result+=
      Copy(EventTimes[i], 6, MaxInt)+' '+
      IntToStr(tick)+'ms';
  end;
  Result+= ')';
end;

procedure TAppPython.InitModuleMain;
begin
  with FEngine do
    if ModuleMain=nil then
    begin
      ModuleMain:= GetMainModule;
      if ModuleMain=nil then
        raise EPythonError.Create('Python: cannot init __main__');
      if GlobalsMain=nil then
        GlobalsMain:= PyModule_GetDict(ModuleMain);
    end;
end;

procedure TAppPython.InitModuleCud;
begin
  with FEngine do
    if ModuleCud=nil then
    begin
      ModuleCud:= ImportModuleCached('cudatext');
      if ModuleCud=nil then
        raise EPythonError.Create('Python: cannot import "cudatext"');
      if GlobalsCud=nil then
        GlobalsCud:= PyModule_GetDict(ModuleCud);
    end;
end;

function TAppPython.Eval(const Command: string; UseFileMode: boolean=false): PPyObject;
var
  Mode: integer;
begin
  Result := nil;
  if not FInited then exit;

  if UseFileMode then
    Mode:= file_input
  else
    Mode:= eval_input;

  with FEngine do
  begin
    Traceback.Clear;
    CheckError(False);

    InitModuleMain;

    try
      //PythonEngine used PChar(CleanString(Command)) - is it needed?
      Result := PyRun_String(PChar(Command), Mode, GlobalsMain, GlobalsMain); //seems no need separate Locals
      if Result = nil then
        CheckError(False);
    except
      if PyErr_Occurred <> nil then
        CheckError(False)
      else
        raise;
    end;
  end;
end;

procedure TAppPython.Exec(const Command: string);
begin
  if not FInited then exit;
  with FEngine do
    Py_XDECREF(Eval(Command, true));
    //UseFileMode=True to allow running several statements with ";"
end;

function TAppPython.MethodEvalObjects(const AObject, AFunc: string;
  const AParams: array of PPyObject): PPyObject;
var
  CurrObject, Func, Params: PPyObject;
  i: integer;
begin
  Result:=nil;
  if not FInited then exit;
  InitModuleMain;
  with FEngine do
  begin
    CurrObject:=PyDict_GetItemString(GlobalsMain,PChar(AObject));
    if Assigned(CurrObject) then
    begin
      Func:=PyObject_GetAttrString(CurrObject,PChar(AFunc));
      if Assigned(Func) then
        try
          Params:=PyTuple_New(Length(AParams){+1});
          if Assigned(Params) then
          try
            ////seems additional "self" is not needed
            //PyTuple_SetItem(Params,0,CurrObject);
            for i:=0 to Length(AParams)-1 do
              if PyTuple_SetItem(Params,i,AParams[i])<>0 then
                RaiseError;
            Result:=PyObject_Call(Func,Params,nil);
          finally
            Py_DECREF(Params);
          end;
        finally
          Py_DECREF(Func);
        end;
    end;
  end;
end;

function TAppPython.MethodEvalEx(const AObject, AMethod: string;
  const AParams: array of PPyObject): TAppPyEventResult;
var
  Obj: PPyObject;
begin
  Result.Val:= evrOther;
  Result.Str:= '';

  with FEngine do
  begin
    Obj:= MethodEvalObjects(AObject, AMethod, AParams);
    if Assigned(Obj) then
    try
      if Pointer(Obj)=Pointer(Py_True) then
        Result.Val:= evrTrue
      else
      if Pointer(Obj)=Pointer(Py_False) then
        Result.Val:= evrFalse
      else
      if Obj^.ob_type=PyUnicode_Type then
      begin
        Result.Val:= evrString;
        Result.Str:= PyUnicode_AsWideString(Obj);
      end;
    finally
      Py_XDECREF(Obj);
    end;
  end;
end;


procedure TAppPython.ImportCommand(const AObject, AModule: string);
begin
  Exec(Format('import %s;%s=%s.Command()', [AModule, AObject, AModule]));
end;

function TAppPython.RunCommand(const AModule, AMethod: string; const AParams: TAppVariantArray): boolean;
var
  ObjName: string;
  ParamObjs: array of PPyObject;
  Obj: PPyObject;
  i: integer;
begin
  FRunning:= true;
  FLastCommandModule:= AModule;
  FLastCommandMethod:= AMethod;
  if Length(AParams)>0 then
    FLastCommandParam:= AParams[0]
  else
    FLastCommandParam:= AppVariantNil;

  ObjName:= NamePrefix+AModule;

  if not IsLoadedLocal(ObjName) then
  begin
    if UiOps.PyInitLog then
      MsgLogConsole('Init: '+AModule);
    try
      ImportCommand(ObjName, AModule);
      LoadedLocals.Add(ObjName);
    except
    end;
  end;

  try
    SetLength(ParamObjs, Length(AParams));
    for i:= 0 to Length(AParams)-1 do
      ParamObjs[i]:= AppVariantToPyObject(AParams[i]);

    //Obj:= MethodEval(ObjName, AMethod, AppVariantArrayToString(AParams));
    Obj:= MethodEvalObjects(ObjName, AMethod, ParamObjs);
    if Assigned(Obj) then
      with FEngine do
      begin
        //only check for False
        Result:= Pointer(Obj)<>Pointer(Py_False);
        Py_XDECREF(Obj);
      end;
  finally
    FRunning:= false;
  end;
end;

function TAppPython.RunEvent(const AModule, ACmd: string; AEd: TObject;
  const AParams: TAppVariantArray; ALazy: boolean): TAppPyEventResult;
var
  ParamsObj: array of PPyObject;
//
  procedure InitParamsObj;
  var
    ObjEditor, ObjEditorArgs: PPyObject;
    i: integer;
  begin
    SetLength(ParamsObj, Length(AParams)+1);

    //first param must be None or Editor(AEd_handle)
    with FEngine do
      if AEd=nil then
        ParamsObj[0]:= ReturnNone
      else
      begin
        InitModuleCud;
        ObjEditor:= PyDict_GetItemString(GlobalsCud, 'Editor');
        if ObjEditor=nil then
          raise Exception.Create('Python: cannot find cudatext.Editor');
        ObjEditorArgs:= PyTuple_New(1);
        PyTuple_SetItem(ObjEditorArgs, 0, PyLong_FromLongLong(PtrInt(AEd)));
        ParamsObj[0]:= PyObject_CallObject(ObjEditor, ObjEditorArgs);
        Py_XDECREF(ObjEditorArgs);
      end;

    for i:= 0 to Length(AParams)-1 do
      ParamsObj[i+1]:= AppVariantToPyObject(AParams[i]);
  end;
  //
var
  ObjName: string;
  tick: QWord;
  i: integer;
begin
  Result.Val:= evrOther;
  Result.Str:= '';

  FRunning:= true;
  if Assigned(EventTimes) then
    tick:= GetTickCount64;

  ObjName:= NamePrefix+AModule;

  if not ALazy then
  begin
    if not IsLoadedLocal(ObjName) then
    begin
      if UiOps.PyInitLog then
        MsgLogConsole('Init: '+AModule);
      try
        ImportCommand(ObjName, AModule);
        LoadedLocals.Add(ObjName);
      except
      end;
    end;

    InitParamsObj;
    Result:= MethodEvalEx(ObjName, ACmd, ParamsObj);
  end
  else
  //lazy event: run only of ObjName already created
  if IsLoadedLocal(ObjName) then
  begin
    InitParamsObj;
    Result:= MethodEvalEx(ObjName, ACmd, ParamsObj);
  end;

  FRunning:= false;

  if Assigned(EventTimes) then
  begin
    tick:= GetTickCount64-tick;
    if tick>0 then
    begin
      Inc(EventTime, tick);
      i:= EventTimes.IndexOf(AModule);
      if i>=0 then
        EventTimes.Objects[i]:= TObject(PtrInt(EventTimes.Objects[i])+PtrInt(tick))
      else
        EventTimes.AddObject(AModule, TObject(PtrInt(tick)));
    end;
  end;
end;


function TAppPython.ImportModuleCached(const AModule: string): PPyObject;
var
  N: integer;
begin
  N:= LoadedModules.IndexOf(AModule);
  if N>=0 then
    Result:= PPyObject(LoadedModules.Objects[N])
  else
  begin
    if UiOps.PyInitLog then
      MsgLogConsole('Init: '+AModule);
    Result:= FEngine.PyImport_ImportModule(PChar(AModule));
    LoadedModules.AddObject(AModule, TObject(Result))
  end;
end;

function TAppPython.RunModuleFunction(const AModule,AFunc:string;
  const AParams:array of PPyObject;
  const AParamNames:array of string):PPyObject;
var
  Module,ModuleDic,Func,Params,ParamsDic:PPyObject;
  i,UnnamedCount:integer;
begin
  Result:=nil;
  if not FInited then exit;
  with FEngine do
  begin
    Module:=ImportModuleCached(AModule);
    if Assigned(Module) then
    try
      ModuleDic:=PyModule_GetDict(Module);
      if Assigned(ModuleDic) then
      begin
        Func:=PyDict_GetItemString(ModuleDic,PChar(AFunc));
        if Assigned(Func) then
        begin
          UnnamedCount:=Length(AParams)-Length(AParamNames);
          Params:=PyTuple_New(UnnamedCount);
          if Assigned(Params) then
            try
              ParamsDic:=PyDict_New();
              if Assigned(ParamsDic) then
                try
                  for i:=0 to UnnamedCount-1 do
                    if PyTuple_SetItem(Params,i,AParams[i])<>0 then
                      RaiseError;
                  for i:=0 to Length(AParamNames)-1 do
                    if PyDict_SetItemString(ParamsDic,PChar(AParamNames[i]),AParams[UnnamedCount+i])<>0 then
                      RaiseError;
                  Result:=PyObject_Call(Func,Params,ParamsDic);
                finally
                  Py_DECREF(ParamsDic);
                end;
            finally
              Py_DECREF(Params);
            end;
        end;
      end;
    finally
    end;
  end;
end;

function TAppPython.RunModuleFunction(const AModule, AFunc: string;
  const AParams: array of PPyObject): PPyObject;
var
  Module,ModuleDic,Func,Params:PPyObject;
  i:integer;
begin
  Result:=nil;
  if not FInited then exit;
  with FEngine do
  begin
    Module:=ImportModuleCached(AModule);
    if Assigned(Module) then
    try
      ModuleDic:=PyModule_GetDict(Module);
      if Assigned(ModuleDic) then
      begin
        Func:=PyDict_GetItemString(ModuleDic,PChar(AFunc));
        if Assigned(Func) then
        begin
          Params:=PyTuple_New(Length(AParams));
          if Assigned(Params) then
          try
            for i:=0 to Length(AParams)-1 do
              if PyTuple_SetItem(Params,i,AParams[i])<>0 then
                RaiseError;
            Result:=PyObject_Call(Func,Params,nil);
          finally
            Py_DECREF(Params);
          end;
        end;
      end;
    finally
    end;
  end;
end;


function TAppPython.ValueFromString(const S: string): PPyObject;
var
  Num: Int64;
begin
  with FEngine do
  begin
    if S='' then
      Result:= ReturnNone
    else
    if (S[1]='"') or (S[1]='''') then
      Result:= PyString_FromString(PChar( Copy(S, 2, Length(S)-2) ))
    else
    if S='False' then
      Result:= PyBool_FromLong(0)
    else
    if S='True' then
      Result:= PyBool_FromLong(1)
    else
    if TryStrToInt64(S, Num) then
      Result:= PyLong_FromLongLong(Num)
    else
      Result:= ReturnNone;
  end;
end;

function TAppPython.ValueToString(Obj: PPyObject; QuoteStrings: boolean): string;
// the same as TPythonEngine.PyObjectAsString but also quotes str values
var
  s: PPyObject;
  w: UnicodeString;
begin
  Result:= '';
  if not Assigned(Obj) then
    Exit;

  with FEngine do
  begin
    if PyUnicode_Check(Obj) then
    begin
      w:= PyUnicode_AsWideString(Obj);
      if QuoteStrings then
        w:= '"'+w+'"';
      Result:= w;
      Exit;
    end;

    s:= PyObject_Str(Obj);
    if Assigned(s) and PyString_Check(s) then
      Result:= PyString_AsDelphiString(s);
    Py_XDECREF(s);
  end;
end;

procedure TAppPython.ClearCache;
var
  i: integer;
  Obj: PPyObject;
begin
  LoadedLocals.Clear;

  with FEngine do
    for i:= 0 to LoadedModules.Count-1 do
    begin
      Obj:= PPyObject(LoadedModules.Objects[i]);
      Py_XDECREF(Obj);
    end;
  LoadedModules.Clear;
end;


procedure TAppPython.SetPath(const Dirs: array of string; DoAdd: boolean);
var
  Str, Sign: string;
  i: Integer;
begin
  Str:= '';
  for i:= 0 to Length(Dirs)-1 do
    Str:= Str + 'r"' + Dirs[i] + '",';
  if DoAdd then
    Sign:= '+='
  else
    Sign:= '=';
  Str:= Format('sys.path %s [%s]', [Sign, Str]);

  Exec(Str+';print("Python %d.%d"%sys.version_info[:2])');
end;


initialization

  AppPython:= TAppPython.Create;

finalization

  FreeAndNil(AppPython);

end.

