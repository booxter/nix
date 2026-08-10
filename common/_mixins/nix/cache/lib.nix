{ lib }:
{
  substituterFor =
    profile: cache:
    let
      profilePriority = cache.priorities.${profile};
      priority = if profilePriority == null then cache.priorities.default else profilePriority;
    in
    cache.substituter + lib.optionalString (priority != null) "?priority=${toString priority}";
}
