package uploadpack

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"gitlab.com/gitlab-org/gitlab-shell/client/testserver"
	"gitlab.com/gitlab-org/gitlab-shell/internal/command/commandargs"
	"gitlab.com/gitlab-org/gitlab-shell/internal/command/readwriter"
	"gitlab.com/gitlab-org/gitlab-shell/internal/config"
	"gitlab.com/gitlab-org/gitlab-shell/internal/testhelper"
	"gitlab.com/gitlab-org/gitlab-shell/internal/testhelper/requesthandlers"
)

func TestUploadPack(t *testing.T) {
	gitalyAddress, testServer, cleanup := testserver.StartGitalyServer(t)
	defer cleanup()

	requests := requesthandlers.BuildAllowedWithGitalyHandlers(t, gitalyAddress)
	url, cleanup := testserver.StartHttpServer(t, requests)
	defer cleanup()

	output := &bytes.Buffer{}
	input := &bytes.Buffer{}

	userId := "1"
	repo := "group/repo"

	cmd := &Command{
		Config:     &config.Config{GitlabUrl: url},
		Args:       &commandargs.Shell{GitlabKeyId: userId, CommandType: commandargs.UploadPack, SshArgs: []string{"git-upload-pack", repo}},
		ReadWriter: &readwriter.ReadWriter{ErrOut: output, Out: output, In: input},
	}

	hook := testhelper.SetupLogger()

	err := cmd.Execute()
	require.NoError(t, err)

	require.Equal(t, "UploadPack: "+repo, output.String())
	entries := hook.AllEntries()
	assert.Equal(t, 2, len(entries))
	require.Contains(t, entries[1].Message, "executing git command")
	require.Contains(t, entries[1].Message, "command=git-upload-pack")
	require.Contains(t, entries[1].Message, "gl_key_type=key")
	require.Contains(t, entries[1].Message, "gl_key_id=123")

	for k, v := range map[string]string{
		"gitaly-feature-cache_invalidator":        "true",
		"gitaly-feature-inforef_uploadpack_cache": "false",
	} {
		actual := testServer.ReceivedMD[k]
		assert.Len(t, actual, 1)
		assert.Equal(t, v, actual[0])
	}
	assert.Empty(t, testServer.ReceivedMD["some-other-ff"])
}
