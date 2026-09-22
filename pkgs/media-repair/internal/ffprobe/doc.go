// Package ffprobe decodes the deliberately restricted JSON emitted by
// ffprobe for Radarr repair evidence.
//
// We use ffprobe's JSON interface directly because we found no maintained Go
// binding that improves this narrow boundary without hiding its data model.
package ffprobe
