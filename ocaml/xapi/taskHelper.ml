(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module D = Debug.Make (struct let name = "taskhelper" end)

open D
module Date = Clock.Date

let with_lock = Xapi_stdext_threads.Threadext.Mutex.execute

let ( let@ ) f x = f x

let finally_complete_tracing ?error __context f =
  Xapi_stdext_pervasives.Pervasiveext.finally f (fun () ->
      Context.complete_tracing ?error __context
  )

type t = API.ref_task

(* creates a new task *)
let make ~__context ~http_other_config ?(description = "") ?session_id
    ?subtask_of label : t * [`task] Uuidx.t =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let uuid = Uuidx.make () in
  let uuid_str = Uuidx.to_string uuid in
  let ref = Ref.make () in
  (* we store in database only parent/child relationship between real tasks *)
  let subtaskid_of =
    match subtask_of with
    | Some task_id when not (Ref.is_dummy task_id) ->
        task_id
    | _e ->
        Ref.null
  in
  let (_ : unit) =
    Db_actions.DB_Action.Task.create ~ref ~__context ~created:(Date.now ())
      ~finished:Date.epoch ~current_operations:[] ~_type:"<none/>"
      ~session:(Option.value ~default:Ref.null session_id)
      ~resident_on:!Xapi_globs.localhost_ref ~status:`pending ~result:""
      ~progress:0. ~error_info:[] ~allowed_operations:[]
      ~name_description:description ~name_label:label ~stunnelpid:(-1L)
      ~forwarded:false ~forwarded_to:Ref.null ~uuid:uuid_str ~externalpid:(-1L)
      ~subtask_of:subtaskid_of
      ~other_config:(List.map (fun (k, v) -> ("http:" ^ k, v)) http_other_config)
      ~backtrace:(Sexplib.Sexp.to_string Backtrace.(sexp_of_t empty))
  in
  (ref, uuid)

let rbac_assert_permission_fn = ref None

(* required to break dep-cycle with rbac.ml *)

let are_auth_user_ids_of_sessions_equal ~__context s1 s2 =
  Context.with_tracing ~__context __FUNCTION__ @@ fun __context ->
  let s1_auth_user_sid =
    Db_actions.DB_Action.Session.get_auth_user_sid ~__context ~self:s1
  in
  let s2_auth_user_sid =
    Db_actions.DB_Action.Session.get_auth_user_sid ~__context ~self:s2
  in
  s1_auth_user_sid = s2_auth_user_sid

let assert_op_valid ?(ok_if_no_session_in_context = false) ~__context task_id =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let assert_permission_task_op_any () =
    match !rbac_assert_permission_fn with
    | None ->
        failwith "no taskhelper.rbac_assert_permission_fn"
        (* shouldn't ever happen *)
    | Some fn ->
        fn ~__context ~permission:Rbac_static.permission_task_destroy_any
  in
  let context_session =
    try Some (Context.get_session_id __context) with Failure _ -> None
  in
  match context_session with
  | None ->
      (* no session in context *)
      if ok_if_no_session_in_context then
        ()
      (* only internal xapi calls (eg db_gc) have no session in contexts, so rbac can be ignored *)
      else
        assert_permission_task_op_any ()
      (* will raise "no-session-in-context" exception *)
  | Some context_session ->
      let is_own_task =
        try
          (* If the task id is the same as the context's task id, we don't need
             to go theough their respective sessions.*)
          match Context.get_task_id __context = task_id with
          | true ->
              true
          | false ->
              are_auth_user_ids_of_sessions_equal ~__context context_session
                (Db_actions.DB_Action.Task.get_session ~__context ~self:task_id)
        with e ->
          debug "assert_op_valid: %s" (ExnHelper.string_of_exn e) ;
          false
      in
      (*debug "IS_OWN_TASK=%b" is_own_task;*)
      (* 1. any subject can destroy its own tasks *)
      if not is_own_task then
        (* 2. if not own task, has this session permission to destroy any tasks? *)
        assert_permission_task_op_any ()

let get_name ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let task_id = Context.get_task_id __context in
  if Ref.is_dummy task_id then
    Ref.name_of_dummy task_id
  else
    Db.Task.get_name_label ~__context ~self:task_id

let destroy ~__context task_id =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  if not (Ref.is_dummy task_id) then (
    assert_op_valid ~ok_if_no_session_in_context:true ~__context task_id ;
    Db_actions.DB_Action.Task.destroy ~__context ~self:task_id
  )

(* set the ref fn to break the cyclic dependency *)
let init () =
  (Context.__get_task_name :=
     fun ~__context self ->
       Db_actions.DB_Action.Task.get_name_label ~__context ~self
  ) ;
  Context.__destroy_task := destroy ;
  Context.__make_task := make

let operate_on_db_task ~__context f =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  if Context.task_in_database __context then
    f (Context.get_task_id __context)

let set_description ~__context value =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.set_name_description ~__context ~self ~value

let add_to_other_config ~__context key value =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.remove_from_other_config ~__context ~self ~key ;
  Db_actions.DB_Action.Task.add_to_other_config ~__context ~self ~key ~value

let set_progress ~__context value =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.set_progress ~__context ~self ~value

let set_external_pid ~__context pid =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.set_externalpid ~__context ~self
    ~value:(Int64.of_int pid)

let clear_external_pid ~__context = set_external_pid ~__context (-1)

let set_result_on_task ~__context task_id result =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  match result with
  | None ->
      ()
  | Some x ->
      Db_actions.DB_Action.Task.set_result ~__context ~self:task_id
        ~value:(Xmlrpc.to_string x)

(** Only set the result without completing the task. Useful for vm import *)
let set_result ~__context result =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  set_result_on_task ~__context self result

let status_to_string = function
  | `pending ->
      "pending"
  | `success ->
      "success"
  | `failure ->
      "failure"
  | `cancelling ->
      "cancelling"
  | `cancelled ->
      "cancelled"

let status_is_completed task_status =
  task_status = `success || task_status = `failure || task_status = `cancelled

let complete ~__context result =
  let@ () = finally_complete_tracing __context in
  let@ self = operate_on_db_task ~__context in
  let status = Db_actions.DB_Action.Task.get_status ~__context ~self in
  match status with
  | `pending ->
      Db_actions.DB_Action.Task.set_allowed_operations ~__context ~self
        ~value:[] ;
      Db_actions.DB_Action.Task.set_finished ~__context ~self
        ~value:(Date.now ()) ;
      Db_actions.DB_Action.Task.set_progress ~__context ~self ~value:1. ;
      set_result_on_task ~__context self result ;
      Db_actions.DB_Action.Task.set_status ~__context ~self ~value:`success
  | _ ->
      debug "the status of %s is: %s; cannot set it to `success"
        (Ref.really_pretty_and_small self)
        (status_to_string status)

let set_cancellable ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.set_allowed_operations ~__context ~self
    ~value:[`cancel]

let set_not_cancellable ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  Db_actions.DB_Action.Task.set_allowed_operations ~__context ~self ~value:[]

let is_cancelling ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  Context.task_in_database __context
  &&
  let l =
    Db_actions.DB_Action.Task.get_current_operations ~__context
      ~self:(Context.get_task_id __context)
  in
  List.exists (fun (_, x) -> x = `cancel) l

let raise_cancelled ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let task_id = Context.get_task_id __context in
  raise Api_errors.(Server_error (task_cancelled, [Ref.string_of task_id]))

let exn_if_cancelling ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  if is_cancelling ~__context then
    raise_cancelled ~__context

let cancel_this ~__context ~self =
  let@ () = finally_complete_tracing __context in
  assert_op_valid ~__context self ;
  let status = Db_actions.DB_Action.Task.get_status ~__context ~self in
  if status = `pending then (
    Db_actions.DB_Action.Task.set_progress ~__context ~self ~value:1. ;
    Db_actions.DB_Action.Task.set_finished ~__context ~self ~value:(Date.now ()) ;
    Db_actions.DB_Action.Task.set_status ~__context ~self ~value:`cancelled ;
    Db_actions.DB_Action.Task.set_allowed_operations ~__context ~self ~value:[]
  ) else
    debug "the status of %s is %s; cannot set it to `cancelled"
      (Ref.really_pretty_and_small self)
      (status_to_string status)

let cancel ~__context =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let@ self = operate_on_db_task ~__context in
  cancel_this ~__context ~self

let failed ~__context exn =
  let backtrace = Printexc.get_raw_backtrace () in
  let@ () = finally_complete_tracing ~error:(exn, backtrace) __context in
  let code, params = ExnHelper.error_of_exn exn in
  let@ self = operate_on_db_task ~__context in
  let status = Db_actions.DB_Action.Task.get_status ~__context ~self in
  match status with
  | `pending ->
      Db_actions.DB_Action.Task.set_progress ~__context ~self ~value:1. ;
      Db_actions.DB_Action.Task.set_error_info ~__context ~self
        ~value:(code :: params) ;
      Db_actions.DB_Action.Task.set_backtrace ~__context ~self
        ~value:(Sexplib.Sexp.to_string Backtrace.(sexp_of_t (get exn))) ;
      Db_actions.DB_Action.Task.set_finished ~__context ~self
        ~value:(Date.now ()) ;
      Db_actions.DB_Action.Task.set_allowed_operations ~__context ~self
        ~value:[] ;
      if code = Api_errors.task_cancelled then
        Db_actions.DB_Action.Task.set_status ~__context ~self ~value:`cancelled
      else
        Db_actions.DB_Action.Task.set_status ~__context ~self ~value:`failure
  | _ ->
      debug "the status of %s is %s; cannot set it to %s"
        (Ref.really_pretty_and_small self)
        (status_to_string status)
        ( if code = Api_errors.task_cancelled then
            "`cancelled"
          else
            "`failure"
        )

type id = Sm of string | Xenops of string * string

(* queue name * id *)

let id_to_task_tbl : (id, API.ref_task) Hashtbl.t = Hashtbl.create 10

let task_to_id_tbl : (API.ref_task, id) Hashtbl.t = Hashtbl.create 10

let task_tbl_m = Mutex.create ()

let id_to_task_exn id =
  with_lock task_tbl_m (fun () -> Hashtbl.find id_to_task_tbl id)

let task_to_id_exn task =
  with_lock task_tbl_m (fun () -> Hashtbl.find task_to_id_tbl task)

let register_task __context ?(cancellable = true) id =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  let task = Context.get_task_id __context in
  with_lock task_tbl_m (fun () ->
      Hashtbl.replace id_to_task_tbl id task ;
      Hashtbl.replace task_to_id_tbl task id
  ) ;
  (* We bind the XenAPI Task to the xenopsd Task, which is capable of
     cancellation at the low level. If this is not desired behavior, overwrite
     it with the cancellable flag. *)
  if cancellable then
    set_cancellable ~__context
  else
    set_not_cancellable ~__context ;
  ()

let unregister_task __context id =
  let@ __context = Context.with_tracing ~__context __FUNCTION__ in
  (* The rest of the XenAPI Task won't be cancellable *)
  set_not_cancellable ~__context ;
  with_lock task_tbl_m (fun () ->
      let task = Hashtbl.find id_to_task_tbl id in
      Hashtbl.remove id_to_task_tbl id ;
      Hashtbl.remove task_to_id_tbl task
  ) ;
  ()
