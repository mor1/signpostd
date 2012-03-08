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


open Int64


exception Timeout


type node_name = string
type ip = string
type port = int64

type command = string
type arg = string
type id = int64

exception Result_error of string
type result = 
  | Result of string
  | NoResult
let json_of_result = function
    | Result(str) -> Json.String str
    | NoResult -> Json.Null
let result_of_json = function
    | Json.String str -> Result(str)
    | Json.Null -> NoResult
    | _ -> raise (Result_error("result_of_json"))
    
exception Error_error of string
type error = 
  | Error of string
  | NoError
let json_of_error = function
    | Error(str) -> Json.String str
    | NoError -> Json.Null
let error_of_json = function
    | Json.String str -> Error(str)
    | Json.Null -> NoError
    | _ -> raise (Error_error("error_of_json"))

exception Invalid_action of string
type action =
    | TEST
    | CONNECT
    | TEARDOWN
let string_of_action = function
    | TEST -> "test"
    | CONNECT -> "connect"
    | TEARDOWN -> "teardown"
let action_of_string = function
    | "test" -> TEST
    | "connect" -> CONNECT
    | "teardown" -> TEARDOWN
    | act -> let msg = Printf.sprintf "Invalid action %s" act in 
    raise (Invalid_action(msg))

exception Invalid_sp_msg
type rpc = 
  | Hello of node_name * ip * port * ip list
  | Request of command * arg list * id
  | Notification of command * arg list
  | Response of result * error * id
  | Tactic_request of string * action * arg list * id
  | Tactic_response of string * result * error * id


let rpc_id_counter = ref 0

let rec string_list_of_json_list = function
    | (Json.String(ip)) :: ips -> [ip] @ (string_list_of_json_list ips)
    | [] -> []
    | _ -> raise (Invalid_argument "Invalid arg on string_list_of_json_list")

let rec json_list_of_string_list = function
    | ip :: ips -> [(Json.String ip)] @ (json_list_of_string_list ips)
    | [] -> []

let rpc_to_json rpc =
  let open Json in
  Object [
    match rpc with
    | Hello (n, i, p, ips) ->
        "hello", (Array [ String n; String i; Int p; 
        Array (json_list_of_string_list ips)])
    (* Based on the specifications of JSON-RPC:
     * http://json-rpc.org/wiki/specification *)
    | Request (c, string_args, id) -> 
        let args = List.map (fun a -> String a) string_args in
        "request", (Object [
          ("method", String c);
          ("params", Array args);
          ("id", Int id)
        ])
    | Notification (c, string_args) -> 
        let args = List.map (fun a -> String a) string_args in
        "notification", (Object [
          ("method", String c);
          ("params", Array args);
          ("id", Null)
        ])
    (* When there was an error, the result must be nil *)
    | Response (_r, Error e, id) -> 
        "response", (Object [
          ("result", Null);
          ("error", String e);
          ("id", Int id)
        ])
    (* When there is a result, the error has to be nil *)
    | Response (Result r, _e, id) -> 
        "response", (Object [
          ("result", String r);
          ("error", Null);
          ("id", Int id)
        ])
    | Tactic_request (name, act, args, id) ->
            "request", (Object [
                "tactic", (Object [
                    ("name", String name);
                    ("action", String (string_of_action act));
                    ("args", Array (json_list_of_string_list args));
                    ("id", Int id)
                ])
            ])
    | Tactic_response (name, result, error, id) ->
            "response", (Object [
                "tactic", (Object [
                    ("name", String name);
                    ("result", (json_of_result result));
                    ("error", (json_of_error error));
                    ("id", Int id)
                ])
            ])
    | _ -> raise (Invalid_sp_msg)
   ]

let get_entry_of_name entries name =
  let find_fun = function
    | (n, entry) -> n=name
    | _ -> false in
  let (_, entry) = List.find find_fun entries in
  entry

let rpc_of_json =
  let open Json in
  function
    | Object [ "hello", (Array [String n; String i; Int p; Array ips]) ] ->
        Some (Hello (n,i, p, (string_list_of_json_list ips)))
    | Object [ "request", (Object [ "tactic", (Object [
      ("name", String name); ("action", String act);
      ("args", Array args); ("id", Int id) ])])] ->
        Some (Tactic_request (name, (action_of_string act), 
        (string_list_of_json_list args), id))
    | Object [ "response", (Object [
      "tactic", (Object [
        ("name", String name); ("result", result);
        ("error", error); ("id", Int id) ]) ]) ] -> 
          Some (Tactic_response (name, (result_of_json result), 
          (error_of_json error), id) )
    | Object [ "request", Object entries ] ->
        let String c = get_entry_of_name entries "method" in
        let Array args = get_entry_of_name entries "params" in
        let Int id = get_entry_of_name entries "id" in
        let string_args = List.map (function
          | String s -> s
          | Int i -> (string_of_int (to_int i))) args in
        Some(Request(c, string_args, id))
    | Object [ "notification", Object [
      ("method", String c);
      ("params", Array args);
      ("id", Null) ] ] ->
        let string_args = List.map (fun (String s) -> s) args in
        Some(Notification(c, string_args))
    | Object [ "response", Object [
      ("result", String result);
      ("error", Null);
      ("id", Int id) ] ] ->
        Some(Response(Result result, NoError, id))
    | Object [ "response", Object [
      ("result", Null);
      ("error", String e);
      ("id", Int id) ] ] ->
        Some(Response(NoResult, Error e, id))
    | _ -> None
 
let rpc_to_string rpc =
  Json.to_string (rpc_to_json rpc)

let rpc_of_string s =
  let json = try Some (Json.of_string s) with _ -> None in
  match json with
  | None -> None
  | Some x -> rpc_of_json x

let fresh_id () =
  rpc_id_counter := !rpc_id_counter + 1;
  of_int !rpc_id_counter

let create_request method_name args =
  let id = fresh_id () in
  Request(method_name, args, id)

let create_notification method_name args =
  Notification(method_name, args)

let create_response_ok result id =
  Response(Result result, NoError, id)

let create_response_error error id =
  Response(NoResult, Error error, id)

let create_tactic_request tactic action args =
  let id = fresh_id () in
  Tactic_request(tactic, action, args, id)

let create_tactic_response tactic result error args =
  let id = fresh_id () in
  Tactic_request(tactic, result, error , id)

let create_tactic_response_ok tactic result id =
    Tactic_response (tactic, Result(result), 
    NoError, id) 

let create_tactic_response_err tactic err id =
    Tactic_response (tactic, NoResult, Error(err), id) 
