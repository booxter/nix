{
  imports = [
    (import ../servarr {
      name = "lidarr";
      apiGroup = "lidarr-api";
      addUserToApiGroup = false;
    })
  ];
}
