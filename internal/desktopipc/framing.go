package desktopipc

import (
	"encoding/binary"
	"fmt"
	"io"
)

func ReadFrame(reader io.Reader) ([]byte, error) {
	header := make([]byte, FrameHeaderBytes)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(header)
	if length == 0 || length > MaxFrameBytes {
		return nil, fmt.Errorf("Desktop IPC frame length %d is outside the allowed range", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func WriteFrame(writer io.Writer, payload []byte) error {
	if len(payload) == 0 || len(payload) > MaxFrameBytes {
		return fmt.Errorf("Desktop IPC frame length %d is outside the allowed range", len(payload))
	}
	frame := make([]byte, FrameHeaderBytes+len(payload))
	binary.LittleEndian.PutUint32(frame[:FrameHeaderBytes], uint32(len(payload)))
	copy(frame[FrameHeaderBytes:], payload)
	for len(frame) > 0 {
		written, err := writer.Write(frame)
		if err != nil {
			return err
		}
		if written <= 0 || written > len(frame) {
			return io.ErrShortWrite
		}
		frame = frame[written:]
	}
	return nil
}
