let
  directory = "/run/alloy-otlp";
  socket = "${directory}/otlp.sock";
in
{
  inherit directory socket;
  endpoint = "unix://${socket}";
}
