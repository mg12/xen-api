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

(** {2 Debug utilities} *)

val init_logs : unit -> unit
(** Register a Logs reporter to collect and report log messages from libraries
    using Logs *)

(** {2 Associate a task to the current actions} *)

val with_thread_associated :
  ?client:string -> ?quiet:bool -> string -> ('a -> 'b) -> 'a -> 'b
(** Do an action with a task name associated with the current thread *)

(** {2 Associate a name to the current thread} *)

val with_thread_named : string -> ('a -> 'b) -> 'a -> 'b
(** Do an action with a name associated with the current thread *)

module type BRAND = sig
  val name : string
end

val gettimestring : unit -> string
(** The current time of day in a format suitable for logging *)

val set_facility : Syslog.facility -> unit
(** Set the syslog facility that will be used by this program. *)

val disable : ?level:Syslog.level -> string -> unit
(** [disable brand] Suppress all log output from the given [brand]. Specifying a
    [level] disables * only this log level, otherwise all levels for the given
    [brand] are disabled. * This function is idempotent. *)

val set_level : Syslog.level -> unit
(** [set_level level] Disable all log output below [level]. * This function is
    idempotent. *)

val disabled_modules : unit -> (string * Syslog.level) list
(** List describing which modules have logging currently disabled *)

val log_to_stdout : unit -> unit
(** [log_to_stdout ()] will echo all log output to stdout (not the default) *)

val log_backtrace : exn -> Backtrace.t -> unit
(** Write the backtrace associated with [exn] to the log *)

module type DEBUG = sig
  val debug : ('a, unit, string, unit) format4 -> 'a
  (** Debug function *)

  val warn : ('a, unit, string, unit) format4 -> 'a
  (** Warn function *)

  val info : ('a, unit, string, unit) format4 -> 'a
  (** Info function *)

  val error : ('a, unit, string, unit) format4 -> 'a
  (** Error function *)

  val critical : ('a, unit, string, unit) format4 -> 'a
  (** Critical function *)

  val audit : ?raw:bool -> ('a, unit, string, string) format4 -> 'a
  (** Audit function *)

  val log_backtrace : exn -> unit
  (** [log_backtrace exn] logs the backtrace associated with [exn].
      Either this or {!Backtrace.is_important} must be the first statement in an exception handler,
      otherwise the backtrace may be overwritten (e.g. by formatting functions that internally raise and catch exceptions).

      This has to be used instead of getting a new backtrace from Printexc if [Backtrace.is_important] was ever called,
      because that function stashes away the backtrace and then overwrites the current backtrace (to avoid duplicate frames in the stacktrace,
      when Backtrace.get is used).
   *)

  val log_and_ignore_exn : (unit -> unit) -> unit
end

module Make : functor (_ : BRAND) -> DEBUG

(** {3 Utility functions for the test code} *)

val is_disabled : string -> Syslog.level -> bool
(** [is_disabled brand level] returns [true] if logging for [brand] at [level]
    is disabled, * otherwise returns [false]. *)

module Pp : sig
  val mtime_span : unit -> Mtime.Span.t -> string

  val signal : unit -> int -> string
  (** signal pretty-prints an ocaml signal number as its POSIX name, see
      {Fmt.Dump.signal} *)
end
