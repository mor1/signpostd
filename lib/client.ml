(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)


open Lwt
open Printf
open Int64
open Re_str

module DP = Dns.Packet
module IncomingSignalling = SignalHandler.Make (ClientSignalling)


let our_domain = sprintf "d%d.%s" Config.signpost_number Config.domain
let node_name = ref "unknown"
let node_ip = ref "unknown"
let node_port = ref (of_int 0)
let local_ips = ref []
let ns_fd = (Lwt_unix.(socket PF_INET SOCK_DGRAM 0))
let sp_fd = (Lwt_unix.(socket PF_INET SOCK_DGRAM 0))
let ns_fd_bind = ref true

let usage () = eprintf "Usage: %s <node-name> <node-ip> <node-signalling-port>\n%!" Sys.argv.(0); exit 1

(*checks if list v2 is a sublist of v1 *)
let rec compareVs v1 v2 = match v1, v2 with
  | [], _ -> false
  | _, [] -> true
  | x::xs, y::ys -> 
(*       Printf.printf "%s %s\n%!" x y; *)
      x = y && compareVs xs ys

let nxdomain =
  {Dns.Query.rcode=DP.NXDomain; aa=false; answer=[]; authority=[]; additional=[]}

let bind_ns_fd () =
  if (!ns_fd_bind) then (
    let src = Unix.ADDR_INET(Unix.inet_addr_any, 25000) in 
      ns_fd_bind := false;
    Lwt_unix.bind ns_fd src;
    let src = Unix.ADDR_INET(Unix.inet_addr_any, 25001) in 
      Lwt_unix.bind sp_fd src;)
    else ()

let forward_dns_query_to_ns packet _ = 
  let buf = Lwt_bytes.create 4096 in
  let data = DP.marshal buf packet in
  let dst =
    Lwt_unix.ADDR_INET((Unix.inet_addr_of_string Config.ns_server), 53) 
  in
  lwt _ = Lwt_bytes.sendto ns_fd data 0 (Cstruct.len data) [] dst in
  
  let buflen = 1514 in
  let buf = Lwt_bytes.create buflen in 
  lwt (len, _) = Lwt_bytes.recvfrom ns_fd buf 0 buflen [] in 
  let names = Hashtbl.create 8 in 
  let reply = DP.parse names buf in
  let q_reply =
    let module DQ = Dns.Query in
    let rcode = DP.(reply.detail.rcode) in
    let aa = DP.(reply.detail.aa) in
    DQ.({ rcode; aa;
          answer = reply.DP.answers;
          authority = reply.DP.authorities;
          additional = reply.DP.additionals;
        })
  in
  return (Some q_reply)

let forward_dns_query_to_sp _ q = 
  let module DP = Dns.Packet in
  let module DQ = Dns.Query in
  (* Normalise the domain names to lower case *)
  let dst = String.lowercase (List.hd q.DP.q_name) in
  let src = !node_name in 
  let host = (Printf.sprintf "%s.%s.%s" dst src our_domain) in  
  lwt src_ip = 
      Dns_resolver.gethostbyname
        ~server:Config.external_ip ~dns_port:Config.dns_port host
  in
  match src_ip with
    | [] ->
        return(Some(nxdomain))
    | src_ip::_ -> 
        return(Some(DQ.({rcode=DP.NoError; aa=true;
                  answer=[
                    DP.({name=q.DP.q_name; cls=RR_IN;
                         ttl=60l; rdata=A(src_ip);})];
                     authority=[]; additional=[];}) ))

  (* Figure out the response from a query packet and its question section *)
let get_response packet q = 
  let open Dns.Packet in
  let module DQ = Dns.Query in
  bind_ns_fd ();
  let qnames = List.map String.lowercase q.q_name in
  eprintf "Q: %s\n%!" (String.concat " " qnames);
  let domain = Re_str.(split (regexp_string ".") our_domain) in 
  if (compareVs (List.rev qnames) (List.rev domain)) then
    forward_dns_query_to_sp packet q 
  else
    forward_dns_query_to_ns packet q   

let dnsfn ~src ~dst packet =
  let open Dns.Packet in
  match packet.questions with
    | [] -> eprintf "bad dns query: no questions\n%!"; return None
    | [q] -> (get_response packet q )
    | _ -> eprintf "dns dns query: multiple questions\n%!"; return None

let dns_t () =
  lwt fd, src = Dns_server.bind_fd ~address:"127.0.0.1" ~port:53 in
    Dns_server.listen ~fd ~src ~dnsfn 

let get_hello_rpc ips =
  let string_port = (string_of_int (to_int !node_port)) in
  let ip_stream = (Unix.open_process_in
                     (Config.dir ^ 
                      "/client_tactics/get_local_device br0")) in
  let test = Re_str.split (Re_str.regexp " ") 
              (input_line ip_stream) in 
  let _::mac::_ = test in
(*   let mac = Net_cache.Arp_cache.mac_of_string mac in  *)
  let args = [!node_name; !node_ip; string_port; mac;] @ ips in
    Rpc.create_notification "hello" args

let update_server_if_state_has_changed () =
  let ips = Nodes.discover_local_ips () in
  match (ips <> !local_ips) with
  | true -> begin
      local_ips := ips;
      let hello_rpc = get_hello_rpc !local_ips in
      Nodes.send_to_server hello_rpc
  end
  | false ->
      return ()

let client_t () =
  lwt _ = Net_cache.Routing.load_routing_table () in
  lwt _ = Net_cache.Arp_cache.load_arp () in
  let xmit_t =
    while_lwt true do
      update_server_if_state_has_changed ();
      Lwt_unix.sleep 2.0
    done
  in
  xmit_t

let signal_t  wakener_connect wakener_end ~port =
  IncomingSignalling.thread_client  wakener_connect wakener_end 
    ~address:Config.external_ip ~port

let _ =
  (try node_name := Sys.argv.(1) with _ -> usage ());

  Nodes.set_local_name !node_name;
  (try node_ip := Sys.argv.(2) with _ -> usage ());
  (try node_port := (of_int (int_of_string Sys.argv.(3))) with _ -> usage ());
  let waiter_connect, wakener_connect = Lwt.task () in
  let waiter_end, wakener_end = Lwt.task () in
  let _ = Lwt.ignore_result 
            (signal_t wakener_connect wakener_end  
               ~port:(Int64.of_int Config.signal_port)) in 
(*   lwt _ = waiter_connect in  *)
  let daemon_t = 
    (waiter_connect >>= 
       (fun _ -> join [ 
         waiter_end; 
         client_t (); 
         dns_t ();
         Sp_controller.listen ();])) in
  Lwt_main.run daemon_t
