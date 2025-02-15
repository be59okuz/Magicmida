unit Dumper;

interface

uses Windows, SysUtils, Classes, Generics.Collections, TlHelp32, PEInfo, Utils;

const
  MAX_IAT_SIZE = $2000; // max 2048 imports

type
  TExportTable = TDictionary<Pointer, string>;

  TRemoteModule = record
    Base, EndOff: PByte;
    Name: string;
    ExportTbl: TExportTable;
  end;
  PRemoteModule = ^TRemoteModule;

  TForwardDict = TDictionary<Pointer, Pointer>;

  TImportThunk = class
  public
    Name: string;
    Addresses: TList<PPointer>;

    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

  TDumper = class
  private
    FProcess: TProcessInformation;
    FOEP, FIAT, FImageBase: NativeUInt;
    FForwards: TForwardDict; // Key: NTDLL, Value: kernel32 (points to API)
    FForwardsType2: TForwardDict; // Key: NTDLL, Value: user32 (points to fwd-string)
    FForwardsOle32: TForwardDict; // Key: combase, Value: ole32
    FForwardsNetapi32: TForwardDict; // Key: netutils, Value: netapi32
    FIATImage: PByte;
    FIATImageSize: Cardinal;

    FUsrPath: PChar;
    FHUsr: HMODULE;

    procedure CollectNTFwd; overload;
    procedure CollectForwards(Fwds: TForwardDict; hModReal, hModScan: HMODULE); overload;
    procedure GatherModuleExportsFromRemoteProcess(M: PRemoteModule);
    function GetLocalProcAddr(hModule: HMODULE; ProcName: PAnsiChar): Pointer;
    function RPM(Address: NativeUInt; Buf: Pointer; BufSize: NativeUInt): Boolean;
  public
    constructor Create(const AProcess: TProcessInformation; AImageBase, AOEP, AIAT: UIntPtr);
    destructor Destroy; override;

    function Process: TPEHeader;
    procedure DumpToFile(const FileName: string; PE: TPEHeader);
  end;

implementation

uses Unit2, Debugger;

{ TDumper }

constructor TDumper.Create(const AProcess: TProcessInformation; AImageBase, AOEP, AIAT: UIntPtr);
begin
  FProcess := AProcess;
  FOEP := AOEP;
  FIAT := AIAT;
  FImageBase := AImageBase;

  if FIAT > $70000000 then
    raise Exception.Create('Wrong IAT address');

  if Win32MajorVersion > 5 then
  begin
    FUsrPath := PChar(ExtractFilePath(ParamStr(0)) + 'mmusr32.dll');
    CopyFile('C:\Windows\system32\user32.dll', FUsrPath, False);
    FHUsr := LoadLibraryEx(FUsrPath, 0, $20) - 2;
  end;

  FForwards := TForwardDict.Create(32);
  FForwardsType2 := TForwardDict.Create(16);
  FForwardsOle32 := TForwardDict.Create(32);
  FForwardsNetapi32 := TForwardDict.Create(32);
  CollectNTFwd;
end;

destructor TDumper.Destroy;
begin
  FForwards.Free;
  FForwardsType2.Free;
  FForwardsOle32.Free;
  FForwardsNetapi32.Free;
  if FIATImage <> nil then
    FreeMem(FIATImage);

  if FHUsr <> 0 then
  begin
    FreeLibrary(FHUsr + 2);
    Windows.DeleteFile(FUsrPath);
  end;

  inherited;
end;

procedure TDumper.CollectNTFwd;
var
  hNetapi: HMODULE;
begin
  CollectForwards(FForwards, GetModuleHandle(kernel32), 0);
  if FHUsr <> 0 then
    CollectForwards(FForwardsType2, GetModuleHandle(user32), FHUsr);
  CollectForwards(FForwardsOle32, GetModuleHandle('ole32.dll'), 0);
  hNetapi := LoadLibrary('netapi32.dll');
  CollectForwards(FForwardsNetapi32, hNetapi, 0);
  FreeLibrary(hNetapi);
end;

procedure TDumper.CollectForwards(Fwds: TForwardDict; hModReal, hModScan: HMODULE);
var
  ModScan: PByte;
  ExpDir: PImageExportDirectory;
  i, Posi: Integer;
  a: PCardinal;
  Fwd: PAnsiChar;
  hMod: HMODULE;
  ProcAddr: Pointer;
begin
  if hModScan = 0 then
    hModScan := hModReal;
  ModScan := Pointer(hModScan);
  ExpDir := Pointer(ModScan + PImageNTHeaders(ModScan + PImageDosHeader(ModScan)._lfanew).OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress);

  a := PCardinal(ModScan + ExpDir.AddressOfFunctions);
  for i := 0 to ExpDir.NumberOfFunctions - 1 do
  begin
    Fwd := PAnsiChar(ModScan + a^); // e.g. NTDLL.RtlAllocateHeap
    Posi := Pos(AnsiString('.'), Fwd);
    if (Length(Fwd) in [10..90]) and (((Posi > 0) and (Posi < 15)) or (Pos(AnsiString('api-ms-win'), Fwd) > 0)) and (Pos(AnsiString('.#'), Fwd) = 0) then
    begin
      hMod := GetModuleHandleA(PAnsiChar(Copy(Fwd, 1, Posi - 1)));
      if hMod > 0 then
      begin
        // Not using the normal GetProcAddress because it can return apphelp hooks (e.g., CoCreateInstance when running as admin)
        ProcAddr := GetLocalProcAddr(hMod, PAnsiChar(Copy(Fwd, Posi + 1, 50)));
        Fwds.AddOrSetValue(ProcAddr, PByte(hModReal) + a^);
        //Log(ltInfo, Format('%s @ %p', [PAnsiChar(Copy(Fwd, Posi + 1, 50)), ProcAddr]));
      end;
    end;
    Inc(a);
  end;
end;

procedure TDumper.DumpToFile(const FileName: string; PE: TPEHeader);
var
  FS: TFileStream;
  Buf: PByte;
  i: Integer;
  Size, Delta: Cardinal;
begin
  FS := TFileStream.Create(FileName, fmCreate);
  try
    Size := PE.DumpSize;
    GetMem(Buf, Size);
    if not RPM(FImageBase, Buf, Size) then
      raise Exception.Create('DumpToFile RPM failed');
    Delta := PE.TrimHugeSections(Buf);
    Dec(Size, Delta);
    Dec(FIAT, Delta);
    FS.Write(Buf^, Size);
    FreeMem(Buf);

    for i := PE.NTHeaders.FileHeader.NumberOfSections to High(PE.Sections) do
    begin
      FS.Write(PE.Sections[i].Data^, PE.Sections[i].Header.SizeOfRawData);
    end;
    PE.NTHeaders.FileHeader.NumberOfSections := Length(PE.Sections);
    PE.NTHeaders.OptionalHeader.AddressOfEntryPoint := FOEP - FImageBase;

    if (PE.NTHeaders.OptionalHeader.DllCharacteristics and $40) <> 0 then
    begin
      Log(ltInfo, 'Executable is ASLR-aware - disabling the flag in the dump');
      PE.NTHeaders.OptionalHeader.DllCharacteristics := PE.NTHeaders.OptionalHeader.DllCharacteristics and not $40;
    end;

    PE.SaveToStream(FS);

    FS.Seek(FIAT - FImageBase, soBeginning);
    FS.Write(FIATImage^, FIATImageSize);
  finally
    FS.Free;
  end;
end;

{$POINTERMATH ON}

function TDumper.Process: TPEHeader;
var
  IAT: PByte;
  i, j: Integer;
  IATSize, Diff: Cardinal;
  PE: TPEHeader;
  a: ^PByte;
  Fwd: Pointer;
  Thunks: TList<TImportThunk>;
  Thunk: TImportThunk;
  NeedNewThunk, Found: Boolean;
  hSnap: THandle;
  ME: TModuleEntry32;
  Modules: TDictionary<string, PRemoteModule>;
  RM: PRemoteModule;
  s: AnsiString;
  Section, Strs, RangeChecker: PByte;
  Descriptors: PImageImportDescriptor;
  ImportSect: PPESection;
begin
  // Read header from memory
  GetMem(Section, $1000);
  RPM(FImageBase, Section, $1000);
  PE := TPEHeader.Create(Section);
  PE.Sanitize;
  FreeMem(Section);

  GetMem(IAT, MAX_IAT_SIZE);
  RPM(FIAT, IAT, MAX_IAT_SIZE);

  IATSize := 0;
  for i := 0 to MAX_IAT_SIZE - 9 do
    if PUInt64(IAT + i)^ = 0 then
    begin
      IATSize := i;
      Break;
    end;

  if IATSize = 0 then
  begin
    for i := 0 to MAX_IAT_SIZE - 13 do
      if (PCardinal(IAT + i)^ = 0) and (PCardinal(IAT + i + 8)^ = 0) and (PCardinal(IAT + i + 4)^ < FImageBase + PE.NTHeaders.OptionalHeader.SizeOfImage) then
      begin
        IATSize := i;
        Break;
      end;

    if IATSize = 0 then
      raise Exception.Create('IAT size could not be determined');
  end;

  with PE.NTHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IAT] do
  begin
    VirtualAddress := FIAT - FImageBase;
    Size := IATSize + 4;
  end;

  Modules := TDictionary<string, PRemoteModule>.Create;
  hSnap := CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, FProcess.dwProcessId);
  ME.dwSize := SizeOf(TModuleEntry32);
  if not Module32First(hSnap, ME) then
    raise Exception.Create('Module32First');
  repeat
    if ME.hModule <> FImageBase then
    begin
      //Log(ltInfo, IntToHex(ME.hModule, 8) + ' : ' + IntToHex(ME.modBaseSize, 4) + ' : ' + string(ME.szModule));
      New(RM);
      RM.Base := ME.modBaseAddr;
      RM.EndOff := ME.modBaseAddr + ME.modBaseSize;
      RM.Name := LowerCase(ME.szModule);
      RM.ExportTbl := nil;
      Modules.AddOrSetValue(RM.Name, RM);
    end;
  until not Module32Next(hSnap, ME);
  CloseHandle(hSnap);

  Thunks := TObjectList<TImportThunk>.Create;
  a := Pointer(IAT);
  NeedNewThunk := False; // whether there's an address "gap" (example: k32-api, 0, k32-api)
  for i := 0 to IATSize div SizeOf(Pointer) - 1 do
  begin
    //Log(ltInfo, IntToHex(UIntPtr(a), 8) + ' -> ' + IntToHex(UIntPtr(a^), 8));
    // Type 2: a^ is correct for export lookup, but need to look in different module! (ntdll --> user32)
    if FForwardsType2.TryGetValue(a^, Fwd) then
    begin
      RangeChecker := Fwd;
    end
    else
    begin
      // Some kernel32 functions are forwarded to ntdll - restore the original address
      if FForwards.TryGetValue(a^, Fwd) then
        a^ := Fwd
      else if FForwardsOle32.TryGetValue(a^, Fwd) then
        a^ := Fwd
      else if FForwardsNetapi32.TryGetValue(a^, Fwd) then
        a^ := Fwd;
      RangeChecker := a^;
    end;

    Found := False;
    for RM in Modules.Values do
      if (RangeChecker > RM.Base) and (RangeChecker < RM.EndOff) then
      begin
        if RM.ExportTbl = nil then
          GatherModuleExportsFromRemoteProcess(RM);

        if RM.ExportTbl.ContainsKey(a^) then
        begin
          if (Thunks.Count = 0) or (Thunks.Last.Name <> RM.Name) or NeedNewThunk then
          begin
            Thunks.Add(TImportThunk.Create(RM.Name));
            NeedNewThunk := False; // reset
          end;

          Found := True;
          //Log(ltInfo, 'IAT ' + IntToHex(UIntPtr(a) - UIntPtr(IAT) + FIAT, 8) + ' -> API ' + IntToHex(UIntPtr(a^), 8) + ' belongs to ' + RM.Name);
          Thunks.Last.Addresses.Add(PPointer(a))
        end
        else
          Log(ltFatal, 'IAT ' + IntToHex(UIntPtr(a) - UIntPtr(IAT) + FIAT, 8) + ' -> API ' + IntToHex(UIntPtr(a^), 8) + ' not in export table of ' + RM.Name + ' (likely a bogus entry)');

        Break;
      end;

    if not Found then
      NeedNewThunk := True;

    Inc(a);
  end;

  ImportSect := PE.CreateSection('.import', $1000);

  Section := AllocMem(ImportSect.Header.SizeOfRawData);
  Pointer(Descriptors) := Section; // Map the Descriptors array to the start of the section
  Strs := Section + (Thunks.Count + 1) * SizeOf(TImageImportDescriptor); // Last descriptor is empty

  i := 0;
  for Thunk in Thunks do
  begin
    Descriptors[i].FirstThunk := (FIAT - FImageBase) + UIntPtr(Thunk.Addresses.First) - UIntPtr(IAT);
    Descriptors[i].Name := PE.ConvertOffsetToRVAVector(ImportSect.Header.PointerToRawData + Cardinal(Strs - Section));
    Inc(i);
    s := AnsiString(Thunk.Name);
    Move(s[1], Strs^, Length(s));
    Inc(Strs, Length(s) + 1);
    RM := Modules[Thunk.Name];
    Log(ltInfo, 'Thunk ' + Thunk.Name + ' - first import: ' + RM.ExportTbl[Thunk.Addresses.First^]);
    for j := 0 to Thunk.Addresses.Count - 1 do
    begin
      Inc(Strs, 2); // Hint
      s := AnsiString(RM.ExportTbl[Thunk.Addresses[j]^]);
      // Set the address in the IAT to this string entry
      Thunk.Addresses[j]^ := Pointer(PE.ConvertOffsetToRVAVector(ImportSect.Header.PointerToRawData + Cardinal(Strs - 2 - Section)));
      Move(s[1], Strs^, Length(s));
      Inc(Strs, Length(s) + 1);

      if Strs > Section + ImportSect.Header.SizeOfRawData - $100 then
      begin
        Inc(ImportSect.Header.SizeOfRawData, $1000);
        Inc(ImportSect.Header.Misc.VirtualSize, $1000);
        Inc(PE.NTHeaders.OptionalHeader.SizeOfImage, $1000);
        Diff := Strs - Section;
        ReallocMem(Section, ImportSect.Header.SizeOfRawData);
        FillChar((Section + ImportSect.Header.SizeOfRawData - $1000)^, $1000, 0);
        Strs := Section + Diff;
        Pointer(Descriptors) := Section;
        //Log(ltInfo, 'Increased import section size to ' + IntToHex(ImportSect.Header.SizeOfRawData, 4));
      end;
    end;
  end;

  ImportSect.Data := Section;
  with PE.NTHeaders.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT] do
  begin
    VirtualAddress := ImportSect.Header.VirtualAddress;
    Size := Thunks.Count * SizeOf(TImageImportDescriptor);
  end;

  Pointer(Descriptors) := nil;
  Thunks.Free;
  for RM in Modules.Values do
  begin
    RM.ExportTbl.Free;
    Dispose(RM);
  end;
  Modules.Free;

  FIATImage := IAT;
  FIATImageSize := IATSize;

  Result := PE;
end;

procedure TDumper.GatherModuleExportsFromRemoteProcess(M: PRemoteModule);
var
  Head: PByte;
  Exp: PImageExportDirectory;
  Off: PByte;
  a, n: PCardinal;
  o: PWord;
  i: Integer;
begin
  M.ExportTbl := TExportTable.Create;
  GetMem(Head, $1000);
  RPM(NativeUInt(M.Base), Head, $1000);
  with PImageNtHeaders(Head + PImageDosHeader(Head)._lfanew).OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT] do
  begin
    GetMem(Exp, Size);
    RPM(NativeUInt(M.Base + VirtualAddress), Exp, Size);
    Off := PByte(Exp) - VirtualAddress;
  end;
  FreeMem(Head);

  Pointer(a) := Off + Exp.AddressOfFunctions;
  Pointer(n) := Off + Exp.AddressOfNames;
  Pointer(o) := Off + Exp.AddressOfNameOrdinals;
  for i := 0 to Exp.NumberOfNames - 1 do
  begin
    M.ExportTbl.AddOrSetValue(M.Base + a[o[i]], string(AnsiString(PAnsiChar(Off + n[i]))));
  end;

  FreeMem(Exp);
end;

function TDumper.GetLocalProcAddr(hModule: HMODULE; ProcName: PAnsiChar): Pointer;
var
  Exp: PImageExportDirectory;
  Off: PByte;
  a, n: PCardinal;
  o: PWord;
  i: Integer;
begin
  with PImageNtHeaders(hModule + Cardinal(PImageDosHeader(hModule)._lfanew)).OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT] do
  begin
    Exp := Pointer(hModule + VirtualAddress);
    Off := PByte(Exp) - VirtualAddress;
  end;

  Pointer(a) := Off + Exp.AddressOfFunctions;
  Pointer(n) := Off + Exp.AddressOfNames;
  Pointer(o) := Off + Exp.AddressOfNameOrdinals;
  for i := 0 to Exp.NumberOfNames - 1 do
    if AnsiStrComp(PAnsiChar(Off + n[i]), ProcName) = 0 then
      Exit(Pointer(hModule + a[o[i]]));

  Result := nil;
end;

function TDumper.RPM(Address: NativeUInt; Buf: Pointer; BufSize: NativeUInt): Boolean;
begin
  Result := ReadProcessMemory(FProcess.hProcess, Pointer(Address), Buf, BufSize, BufSize);
  if not Result then
    Log(ltFatal, 'RPM failed');
end;

{ TImportThunk }

constructor TImportThunk.Create(const AName: string);
begin
  Name := AName;
  Addresses := TList<PPointer>.Create;
end;

destructor TImportThunk.Destroy;
begin
  Addresses.Free;

  inherited;
end;

end.
