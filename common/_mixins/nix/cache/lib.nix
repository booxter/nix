{ lib }:
{
  substituterFor =
    profile: cache:
    let
      priority = cache.priorities.${profile} or cache.priorities.default or null;
    in
    cache.substituter + lib.optionalString (priority != null) "?priority=${toString priority}";
}
