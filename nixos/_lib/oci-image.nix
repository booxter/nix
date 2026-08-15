{
  image,
  pkgs,
}:
{
  ref = "${image.image}:${image.tag}";
  imageFile = pkgs.dockerTools.pullImage {
    imageName = image.image;
    imageDigest = image.digest;
    hash = image.hash;
    finalImageName = image.image;
    finalImageTag = image.tag;
    os = "linux";
    arch = "amd64";
  };
}
