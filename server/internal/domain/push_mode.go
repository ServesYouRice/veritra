package domain

const PushNotificationLegacy = "legacy_generic"
const PushNotificationLocalDecrypt = "local_decrypt_v1"

func ValidPushNotificationMode(mode string) bool {
	return mode == PushNotificationLegacy || mode == PushNotificationLocalDecrypt
}
