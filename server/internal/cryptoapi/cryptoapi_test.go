package cryptoapi

import (
	"context"
	"errors"
	"testing"
)

func TestUnavailableProductionCryptoFailsClosed(t *testing.T) {
	service := UnavailableProductionCrypto{}
	ctx := context.Background()

	ciphertext, metadata, err := service.EncryptEnvelope(ctx, "conversation", []byte{1})
	if !errors.Is(err, ErrProductionCryptoUnavailable) || ciphertext != nil ||
		metadata.Protocol != "" || metadata.Metadata != nil {
		t.Fatalf("EncryptEnvelope did not fail closed: ciphertext=%v metadata=%+v err=%v", ciphertext, metadata, err)
	}

	plaintext, err := service.DecryptEnvelope(ctx, "conversation", []byte{1}, EnvelopeMetadata{})
	if !errors.Is(err, ErrProductionCryptoUnavailable) || plaintext != nil {
		t.Fatalf("DecryptEnvelope did not fail closed: plaintext=%v err=%v", plaintext, err)
	}

	keyPackage, err := service.CreateDeviceKeyPackage(ctx, "account", "device")
	if !errors.Is(err, ErrProductionCryptoUnavailable) || keyPackage.DeviceID != "" ||
		keyPackage.AccountID != "" || keyPackage.KeyPackage != nil || keyPackage.SigningKey != nil {
		t.Fatalf("CreateDeviceKeyPackage did not fail closed: key_package=%+v err=%v", keyPackage, err)
	}
}
