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
(** Module that defines API functions for Subject objects
 * @group XenAPI functions
*)

module D = Debug.Make (struct let name = "xapi_subject" end)

open D

let with_lock = Xapi_stdext_threads.Threadext.Mutex.execute

let run_hook_script_after_subject_add () =
  (* CP-825: Serialize execution of pool-enable-extauth and pool-disable-extauth *)
  (* We should not call the hook script while enabling/disabling the pool's extauth, since that will *)
  (* potentially create different sshd configuration files in different hosts of the pool. *)
  with_lock Xapi_globs.serialize_pool_enable_disable_extauth (fun () ->
      ignore
        (Server_helpers.exec_with_new_task "run_hook_script_after_subject_add"
           (fun __context ->
             Extauth.call_extauth_hook_script_in_pool ~__context
               Extauth.event_name_after_subject_add
         )
        )
  )

let asynchronously_run_hook_script_after_subject_add =
  At_least_once_more.make "running after-subject-add hook script"
    run_hook_script_after_subject_add

let query_subject_information_from_db ~__context identifier =
  let open Xapi_database.Db_filter_types in
  match
    Db.Subject.get_records_where ~__context
      ~expr:(Eq (Field "subject_identifier", Literal identifier))
  with
  | [] ->
      raise Auth_signature.Subject_cannot_be_resolved
  | x :: _ ->
      let subject_r = snd x in
      subject_r.API.subject_other_config

let query_subject_information_from_AD ~__context identifier =
  (Extauth.Ext_auth.d ()).query_subject_information ~__context identifier

let get_subject_information_from_identifier ~__context ~cache identifier =
  if cache then
    query_subject_information_from_db ~__context identifier
  else
    query_subject_information_from_AD ~__context identifier

let create ~__context ~subject_identifier ~other_config:_ =
  (* If at least one of the hosts uses AD external auth, then assert that the AD feature is enabled *)
  let hosts = Db.Host.get_all ~__context in
  let auth_types =
    List.map (fun self -> Db.Host.get_external_auth_type ~__context ~self) hosts
  in
  if List.exists (fun x -> x = Xapi_globs.auth_type_AD) auth_types then
    Pool_features.assert_enabled ~__context ~f:Features.AD ;
  (* we need to find if subject is already in the pool *)
  let subjects = Db.Subject.get_all_records ~__context in
  if
    List.exists
      (fun (_, record) ->
        (* visits each subject in the table o(n) *)
        let subject_id_in_db = record.API.subject_subject_identifier in
        subject_identifier = subject_id_in_db
        (* is it the subject we are looking for? *)
      )
      subjects
  then (
    (* we found an already existing user with the same subject identifier. *)
    (* we should not add another one with the same subject id *)
    debug "subject-id %s already exists in pool" subject_identifier ;
    raise (Api_errors.Server_error (Api_errors.subject_already_exists, []))
  ) else
    (*
		(* one of other_config's fields MUST be 'subject_name' (see interface requirement: ocaml/auth/auth_signature.ml) *)
		(* any other name-value pair is optional *)
		if not (List.mem_assoc "subject_name" other_config)
		then
			let msg = "" (*(String.concat " " (List.map (fun (a,b) -> Printf.sprintf "(%s:%s)" a b) other_config))*) in
			raise (Api_errors.Server_error(Api_errors.subject_name_not_provided, []))
		else
	*)
    (* add the new subject to the db *)
    let ref = Ref.make () in
    let uuid = Uuidx.to_string (Uuidx.make ()) in
    (* CP-1224: Free Edition: Newly created subjects will have the Pool Administrator role. *)
    (* CP-1224: Paid-for Edition: Newly created subjects will have an empty role. *)
    let default_roles =
      if Pool_features.is_enabled ~__context Features.RBAC then
        (* paid-for edition: we can only create a subject with no roles*)
        []
      else (*free edition: one fixed role of pool-admin only*)
        Rbac_static.get_refs [Rbac_static.role_pool_admin]
    in
    (* subject_info is overrided by subject info queried form DC *)
    let subject_info =
      Extauth.call_with_exception_handler @@ fun () ->
      query_subject_information_from_AD ~__context subject_identifier
    in
    Db.Subject.create ~__context ~ref ~uuid ~subject_identifier
      ~other_config:subject_info ~roles:default_roles ;
    (* CP-709: call extauth hook-script after subject.add *)
    (* we fork this call in a new thread so that subject.add *)
    (* does not have to wait for the script to finish in all hosts of the pool *)
    (* optimization to minimize number of concurrent runs of idempotent functions *)
    At_least_once_more.again asynchronously_run_hook_script_after_subject_add ;
    ref

let run_hook_script_after_subject_remove () =
  (* CP-825: Serialize execution of pool-enable-extauth and pool-disable-extauth *)
  (* We should not call the hook script while enabling/disabling the pool's extauth, since that will *)
  (* potentially create different sshd configuration files in different hosts of the pool. *)
  with_lock Xapi_globs.serialize_pool_enable_disable_extauth (fun () ->
      ignore
        (Server_helpers.exec_with_new_task
           "run_hook_script_after_subject_remove" (fun __context ->
             Extauth.call_extauth_hook_script_in_pool ~__context
               Extauth.event_name_after_subject_remove
         )
        )
  )

let asynchronously_run_hook_script_after_subject_remove =
  At_least_once_more.make "running after-subject-remove hook script"
    run_hook_script_after_subject_remove

let destroy ~__context ~self =
  Db.Subject.destroy ~__context ~self ;
  (* CP-709: call extauth hook-script after subject.remove *)
  (* we fork this call in a new thread so that subject.add *)
  (* does not have to wait for the script to finish in all hosts of the pool *)
  (* optimization to minimize number of concurrent runs of idempotent functions *)
  At_least_once_more.again asynchronously_run_hook_script_after_subject_remove

let update ~__context ~self =
  let subject_identifier = Db.Subject.get_subject_identifier ~__context ~self in
  (* query external directory service *)
  (* this might raise an exception *)
  let subject_info =
    Extauth.call_with_exception_handler @@ fun () ->
    query_subject_information_from_AD ~__context subject_identifier
  in
  if Db.Subject.get_other_config ~__context ~self <> subject_info then (
    (* update locally the fresh information received from external directory service *)
    Db.Subject.set_other_config ~__context ~self ~value:subject_info ;
    true
  ) else
    false

let update_all_subjects ~__context =
  (* checks if external authentication is enabled, otherwise it's useless to try to do the update *)
  let host = Helpers.get_localhost ~__context in
  let auth_type = Db.Host.get_external_auth_type ~__context ~self:host in
  if auth_type = "" then
    ( (* external authentication is disabled *)
      (*debug "External authentication is disabled during update_all_subjects";*) )
  else (* external authentication is enabled *)
    let subjects = Db.Subject.get_all ~__context in
    (* visits each subject in the table o(n) *)
    let need_update_config =
      List.fold_left
        (fun updated subj ->
          (* uses a best-effort attempt to update the subject information *)
          (* therefore, if an exception was raised, just ignore it *)
          try update ~__context ~self:subj || updated
          with e ->
            debug "Error trying to update subject %s: %s"
              (Db.Subject.get_subject_identifier ~__context ~self:subj)
              (ExnHelper.string_of_exn e) ;
            (* ignore this exception e, do not raise it again *)
            updated
        )
        false subjects
    in
    if need_update_config then
      with_lock Xapi_globs.serialize_pool_enable_disable_extauth (fun () ->
          Extauth.call_extauth_hook_script_in_pool ~__context
            Extauth.event_name_after_subject_update
          |> ignore
      )

(* This function returns all permissions associated with a subject *)
let get_permissions_name_label ~__context ~self =
  (* for each role in subject.roles:
     	  fold get_all_permissions ~__context ~role
     	  setify
  *)
  Xapi_stdext_std.Listext.List.setify
    (List.fold_left
       (fun accu role ->
         List.rev_append
           (Xapi_role.get_permissions_name_label ~__context ~self:role)
           accu
       )
       []
       (Db.Subject.get_roles ~__context ~self)
    )

let run_hook_script_after_subject_roles_update () =
  (* CP-825: Serialize execution of pool-enable-extauth and pool-disable-extauth *)
  (* We should not call the hook script while enabling/disabling the pool's extauth, since that will *)
  (* potentially create different sshd configuration files in different hosts of the pool. *)
  with_lock Xapi_globs.serialize_pool_enable_disable_extauth (fun () ->
      ignore
        (Server_helpers.exec_with_new_task
           "run_hook_script_after_subject_roles_update" (fun __context ->
             Extauth.call_extauth_hook_script_in_pool ~__context
               Extauth.event_name_after_roles_update
         )
        )
  )

let asynchronously_run_hook_script_after_subject_roles_update =
  At_least_once_more.make "running after-subject-roles-update hook script"
    run_hook_script_after_subject_roles_update

let add_to_roles ~__context ~self ~role =
  (* CP-1224: Free Edition: Attempts to add or remove roles *)
  (* will fail with a LICENSE_RESTRICTION error.*)
  Pool_features.assert_enabled ~__context ~f:Features.RBAC ;
  if Xapi_role.is_valid_role ~__context ~role then
    if List.mem role (Db.Subject.get_roles ~__context ~self) then (
      debug "subject %s already has role %s"
        (Db.Subject.get_subject_identifier ~__context ~self)
        (Ref.string_of role) ;
      raise (Api_errors.Server_error (Api_errors.role_already_exists, []))
    ) else (
      Db.Subject.add_roles ~__context ~self ~value:role ;
      (* CP-710: call extauth hook-script after subject.add_roles *)
      At_least_once_more.again
        asynchronously_run_hook_script_after_subject_roles_update
    )
  else (
    debug "role %s is not valid" (Ref.string_of role) ;
    raise (Api_errors.Server_error (Api_errors.role_not_found, []))
  )

let remove_from_roles ~__context ~self ~role =
  (* CP-1224: Free Edition: Attempts to add or remove roles *)
  (* will fail with a LICENSE_RESTRICTION error.*)
  Pool_features.assert_enabled ~__context ~f:Features.RBAC ;
  if List.mem role (Db.Subject.get_roles ~__context ~self) then (
    Db.Subject.remove_roles ~__context ~self ~value:role ;
    (* CP-710: call extauth hook-script after subject.remove_roles *)
    At_least_once_more.again
      asynchronously_run_hook_script_after_subject_roles_update
  ) else (
    debug "subject %s does not have role %s"
      (Db.Subject.get_subject_identifier ~__context ~self)
      (Ref.string_of role) ;
    raise (Api_errors.Server_error (Api_errors.role_not_found, []))
  )
