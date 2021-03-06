-module(mad_ling).
-author('Maxim Sokhatsky').
-description("LING Erlang Virtual Machine Bundle Packaging").
-copyright('Cloudozer, LLP').
-compile(export_all).
-define(ARCH, list_to_atom( case os:getenv("ARCH") of false -> "posix_x86"; A -> A end)).

main(App) ->
    io:format("ARCH: ~p~n",         [?ARCH]),
    io:format("Bundle Name: ~p~n",  [mad_repl:local_app()]),
    io:format("System: ~p~n",       [mad_repl:system()]),
    io:format("Apps: ~p~n",         [mad_repl:applist()]),
%    io:format("Overlay: ~p~n",      [[{filename:basename(N),size(B)}||{N,B} <- mad_bundle:overlay()]]),
%    io:format("Files: ~p~n",        [[{filename:basename(N),size(B)}||{N,B} <- bundle()]]),
    io:format("Overlay: ~p~n",      [[filename:basename(N)||{N,B} <- mad_bundle:overlay()]]),
    add_apps(),
    false.

cache_dir()       -> ".railing".
local_map(Bucks)  -> list_to_binary(lists:map(fun({B,M,_}) -> io_lib:format("~s /~s\n",[M,B]) end,Bucks)).
bundle()          -> lists:flatten([ mad_bundle:X() || X <- [beams,privs,system_files,overlay] ]).
library(Filename) -> case filename:split(Filename) of
    ["deps","ling","apps",Lib|_] -> list_to_atom(Lib);
                      ["ebin"|_] -> mad_repl:local_app();
                      ["priv"|_] -> mad_repl:local_app();
           A when length(A) >= 3 -> list_to_atom(hd(string:tokens(lists:nth(3,lists:reverse(A)),"-")));
                  ["apps",Lib|_] -> list_to_atom(Lib);
                  ["deps",Lib|_] -> list_to_atom(Lib);
                               _ -> mad_repl:local_app() end.

apps(Ordered) ->
    Overlay = [ {filename:basename(N),B} || {N,B} <- mad_bundle:overlay() ],
    lists:foldl(fun({N,B},Acc) ->
        A = library(N),
        Base = filename:basename(N),
        Body = case lists:keyfind(Base,1,Overlay) of
                    false -> B;
                    {Base,Bin} -> 'overlay', Bin end,
         case lists:keyfind(A,1,Acc) of
              false -> [{A,[{A,Base,Body}]}|Acc];
              {A,Files} -> lists:keyreplace(A,1,Acc,{A,[{A,Base,Body}|Files]}) end
    end,lists:zip(Ordered,lists:duplicate(length(Ordered),[])),bundle()).

lib({App,Files}) ->
   { App, lists:concat(["/erlang/lib/",App,"/ebin"]), Files }.

boot(Ordered) ->
   BootCode = element(2,file:read_file(lists:concat([code:root_dir(),"/bin/start.boot"]))),
   { script, Erlang, Boot } = binary_to_term(BootCode),
   AutoLaunch = {script,Erlang,Boot++[{apply,{application,start,[App]}} || App <- Ordered]},
   io:format("Boot Code: ~p~n",[AutoLaunch]),
   { boot, "start.boot", term_to_binary(AutoLaunch) }.

add_apps() ->
    {ok,Ordered} = mad_plan:orderapps(),
    Bucks = [{boot,"/boot",[local_map, boot(Ordered)]}] ++ [ lib(E) || E <- apps(Ordered) ],
    %io:format("Bucks: ~p~n",[[{App,Mount,[{filename:basename(F),size(Bin)}||{_,F,Bin}<-Files]}||{App,Mount,Files}<-Bucks]]),
    io:format("Bucks: ~p~n",[[{App,Mount,length(Files)}||{App,Mount,Files}<-Bucks]]),
    EmbedFsPath = lists:concat([cache_dir(),"/embed.fs"]),
    io:format("Initializing EMBED.FS:"),
    Res = embed_fs(EmbedFsPath,Bucks),
	{ok, EmbedFsObject} = embedfs_object(EmbedFsPath),
	Res = case sh:oneliner(ld() ++
	           ["vmling.o", EmbedFsObject, "-o", "../" ++ atom_to_list(mad_repl:local_app()) ++ ".img"],
	           cache_dir()) of
	           {_,0,_} -> ok;
	           {_,_,M} -> binary_to_list(M) end,
    io:format("Linking Image: ~p~n",[Res]).

embed_fs(EmbedFsPath,Bucks)  ->
    {ok, EmbedFs} = file:open(EmbedFsPath, [write]),
    BuckCount = length(Bucks),
    BinCount = lists:foldl(fun({_,_,Bins},Count) -> Count + length(Bins) end,0,Bucks),
    file:write(EmbedFs, <<BuckCount:32>>),
	file:write(EmbedFs, <<BinCount:32>>),
    lists:foreach(fun({Buck,_,Bins}) ->
          BuckName = binary:list_to_bin(atom_to_list(Buck)),
          BuckNameSize = size(BuckName),
          BuckBinCount = length(Bins),
          file:write(EmbedFs, <<BuckNameSize, BuckName/binary, BuckBinCount:32>>),
          lists:foreach(fun
                    (local_map) -> LocalMap = local_map(Bucks),
                                   io:format("~nMount View:~n ~s",[LocalMap]),
                                   write_bin(EmbedFs, "local.map", LocalMap);
                  ({App,F,Bin}) -> write_bin(EmbedFs, filename:basename(F), Bin)
          end,Bins)
    end,Bucks),
    file:close(EmbedFs),
	ok.

embedfs_object(EmbedFsPath) ->
	EmbedCPath  = filename:join(filename:absname(cache_dir()), "embedfs.c"),
	OutPath     = filename:join(filename:absname(cache_dir()), "embedfs.o"),
	{ok, Embed} = file:read_file(EmbedFsPath),
	io:format("Creating EMBED.FS C file: ..."),
	Res = bfd_objcopy:blob_to_src(EmbedCPath, "_binary_embed_fs", Embed),
    io:format("~p~n",[Res]),
	io:format("Compilation of Filesystem object: ..."),
	Res = case sh:oneliner(cc() ++ ["-o", OutPath, "-c", EmbedCPath]) of
	           {_,0,_} -> ok;
	           {_,_,M} -> binary_to_list(M) end,
	io:format("~p~n",[Res]),
	{ok, OutPath}.

write_bin(Dev, F, Bin) ->
    {ListName,Data} = case filename:extension(F) of
        ".beam" ->  { filename:rootname(F) ++ ".ling", beam_to_ling(Bin) };
              _ ->  { F, Bin } end,
    Name = binary:list_to_bin(ListName),
    NameSize = size(Name),
    DataSize = size(Data),
    file:write(Dev, <<NameSize, Name/binary, DataSize:32, Data/binary>>).

beam_to_ling(B) ->
    ling_lib:specs_to_binary(element(2,ling_code:ling_to_specs(element(2,ling_code:beam_to_ling(B))))).

gold() -> gold("ld").
gold(Prog) -> [Prog, "-T", "ling.lds", "-nostdlib"].

ld() -> ld(?ARCH).
ld(arm) -> gold("arm-none-eabi-ld");
ld(xen_x86) -> case os:type() of {unix, darwin} -> ["x86_64-pc-linux-ld"]; _ -> gold() end;
ld(posix_x86) -> case os:type() of {unix, darwin} ->
    ["ld","-image_base","0x8000","-pagezero_size","0x8000","-arch","x86_64","-framework","System"];
	_ -> gold() end;
ld(_) -> gold().

cc() -> cc(?ARCH).
cc(arm) -> ["arm-none-eabi-gcc", "-mfpu=vfp", "-mfloat-abi=hard"];
cc(xen_x86) -> case os:type() of {unix, darwin} -> ["x86_64-pc-linux-gcc"]; _ -> ["cc"] end;
cc(_) -> ["cc"].

