package desktopipc

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

type chunkReader struct {
	data []byte
}

type chunkWriter struct {
	data []byte
}

func (w *chunkWriter) Write(source []byte) (int, error) {
	if len(source) == 0 {
		return 0, nil
	}
	w.data = append(w.data, source[0])
	return 1, nil
}

func (r *chunkReader) Read(target []byte) (int, error) {
	if len(r.data) == 0 {
		return 0, io.EOF
	}
	target[0] = r.data[0]
	r.data = r.data[1:]
	return 1, nil
}

func TestReadFrameReassemblesSplitHeaderAndPayload(t *testing.T) {
	var frame bytes.Buffer
	if err := WriteFrame(&frame, []byte(`{"type":"broadcast"}`)); err != nil {
		t.Fatal(err)
	}
	reader := &chunkReader{data: frame.Bytes()}
	payload, err := ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != `{"type":"broadcast"}` {
		t.Fatalf("unexpected payload: %q", payload)
	}
}

func TestReadFrameRejectsOversizedFrameBeforeAllocation(t *testing.T) {
	header := make([]byte, FrameHeaderBytes)
	binary.LittleEndian.PutUint32(header, MaxFrameBytes+1)
	if _, err := ReadFrame(bytes.NewReader(header)); err == nil {
		t.Fatal("oversized frame must be rejected")
	}
}

func TestWriteFrameCompletesPartialWrites(t *testing.T) {
	writer := &chunkWriter{}
	if err := WriteFrame(writer, []byte(`{"ok":true}`)); err != nil {
		t.Fatal(err)
	}
	payload, err := ReadFrame(bytes.NewReader(writer.data))
	if err != nil || string(payload) != `{"ok":true}` {
		t.Fatalf("partial write was not completed: payload=%s err=%v", payload, err)
	}
}
