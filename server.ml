open Containers

let serv_file ~logdir file =
  match IO.File.read (Filename.concat logdir file) with
  | Ok body -> Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body ()
  | Error err -> failwith err

let callback logdir _conn req _body =
  match Uri.path (Cohttp.Request.uri req) with
  | "" | "/" -> serv_file ~logdir "index.html"
  | file ->
      if String.mem ~sub:".." file then
        Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body:"You bastard !" ()
      else
        serv_file ~logdir file

let () =
  match Sys.argv with
  | [|_; logdir|] ->
      let callback = callback logdir in
      Lwt_main.run begin
        Cohttp_lwt_unix.Server.create
          ~mode:(`TCP (`Port 8080))
          (Cohttp_lwt_unix.Server.make ~callback ())
      end
  | _ ->
      prerr_endline "Read the code and try again";
      exit 1
