open Lwt.Infix

module Intf = Intf

type t = Server_workdirs.t
type task = unit -> unit Lwt.t

let get_files dirname =
  Lwt_unix.opendir (Fpath.to_string dirname) >>= fun dir ->
  let rec aux files =
    Lwt.catch begin fun () ->
      Lwt_unix.readdir dir >>= fun file ->
      if Fpath.is_rel_seg file then
        aux files
      else
        aux (file :: files)
    end begin function
    | End_of_file -> Lwt.return files
    | exn -> Lwt.fail exn
    end
  in
  aux [] >>= fun files ->
  Lwt_unix.closedir dir >|= fun () ->
  files

let is_directory dir file =
  if Sys.is_directory (Fpath.to_string (Fpath.add_seg dir file)) then
    Some (Intf.Compiler.from_string file)
  else
    None

let get_compilers workdir =
  let dir = Server_workdirs.logdir workdir in
  get_files dir >|= fun files ->
  let dirs = List.filter_map (is_directory dir) files in
  List.sort Intf.Compiler.compare dirs

module Pkg_tbl = Hashtbl.Make (String)

let pkg_update pkg_tbl comp state pkg =
  let instances =
    match Pkg_tbl.find_opt pkg_tbl pkg with
    | Some instances -> Intf.Instance.create comp state :: instances
    | None -> [Intf.Instance.create comp state]
  in
  Pkg_tbl.replace pkg_tbl pkg instances

let fill_pkgs_from_dir pkg_tbl workdir comp =
  get_files (Server_workdirs.gooddir ~switch:comp workdir) >>= fun good_files ->
  get_files (Server_workdirs.partialdir ~switch:comp workdir) >>= fun partial_files ->
  get_files (Server_workdirs.baddir ~switch:comp workdir) >|= fun bad_files ->
  List.iter (pkg_update pkg_tbl comp Intf.State.Good) good_files;
  List.iter (pkg_update pkg_tbl comp Intf.State.Partial) partial_files;
  List.iter (pkg_update pkg_tbl comp Intf.State.Bad) bad_files

let add_pkg obi full_name instances acc =
  let pkg = Intf.Pkg.name (Intf.Pkg.create ~full_name ~instances:[] ~maintainers:[]) in (* TODO: Remove this horror *)
  let maintainers =
    match List.find_opt (fun pkg' -> String.equal pkg'.Obi.Index.name pkg) obi with
    | Some obi -> obi.Obi.Index.maintainers
    | None -> []
  in
  Intf.Pkg.create ~full_name ~instances ~maintainers :: acc

let get_pkgs obi compilers workdir =
  let pkg_tbl = Pkg_tbl.create 10_000 in
  obi >>= fun obi ->
  compilers >>= fun compilers ->
  Lwt_list.iter_s (fill_pkgs_from_dir pkg_tbl workdir) compilers >|= fun () ->
  let pkgs = Pkg_tbl.fold (add_pkg obi) pkg_tbl [] in
  List.sort Intf.Pkg.compare pkgs

(* TODO: Deduplicate with Server.tcp_server *)
let tcp_server port callback =
  Cohttp_lwt_unix.Server.create
    ~on_exn:(fun _ -> ())
    ~mode:(`TCP (`Port port))
    (Cohttp_lwt_unix.Server.make ~callback ())

let start ~on_finished conf workdir =
  let port = Server_configfile.admin_port conf in
  let callback = Admin.callback ~on_finished workdir in
  Admin.create_admin_key workdir >|= fun () ->
  (workdir, fun () -> tcp_server port callback)