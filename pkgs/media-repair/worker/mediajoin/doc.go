// Package mediajoin runs the fixed FFmpeg operation used to concatenate
// already-authorized media parts.
//
// FFmpeg is kept behind a narrow descriptor-only interface because we found no
// maintained Go binding that improves this operation without exposing libav's
// unsafe API or hiding FFmpeg's container behavior.
package mediajoin
