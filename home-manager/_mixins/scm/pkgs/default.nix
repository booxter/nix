{ pkgs }:
{
  glab-mr-create = pkgs.writeShellApplication {
    name = "glab-mr-create";
    runtimeInputs = [ pkgs.glab ];
    text = ''
      exec glab mr create --fill --remove-source-branch --push "$@"
    '';

    meta = {
      description = "Create a filled GitLab merge request and push its source branch";
      license = pkgs.lib.licenses.mit;
      maintainers = with pkgs.lib.maintainers; [ booxter ];
      mainProgram = "glab-mr-create";
    };
  };
}
