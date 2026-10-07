import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(HERE, "config.json")
LOG_DIR = os.path.join(HERE, "logs")
STORAGE_KEY = "iCubeAuthInfo://icube.cloudide"

SALT_A = bytes([82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
                124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
                84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
                8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37])
SALT_B = bytes([31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
                96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
                160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
                23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125])
SALT_C = bytes([191, 192, 216, 250, 122, 246, 220, 97, 31, 254, 98, 27, 8, 72, 71, 176,
                135, 99, 96, 18, 127, 101, 203, 104, 211, 102, 191, 125, 37, 72, 150, 156,
                51, 229, 121, 35, 17, 153, 141, 177, 110, 131, 150, 128, 172, 255, 254, 6,
                18, 140, 55, 62, 236, 249, 135, 64, 135, 12, 117, 4, 89, 149, 168, 209])
SALT_D = bytes([246, 204, 26, 232, 232, 70, 129, 109, 223, 146, 169, 242, 23, 241, 105, 145,
                50, 196, 165, 42, 254, 120, 3, 54, 244, 207, 209, 85, 53, 6, 138, 106,
                175, 148, 31, 204, 186, 186, 165, 182, 87, 142, 49, 10, 39, 110, 26, 154,
                86, 56, 173, 125, 18, 64, 198, 225, 99, 99, 83, 82, 191, 134, 76, 170])
SALT_AES = bytes(a ^ b for a, b in zip(SALT_A, SALT_B))
SALT_AES_PRIVATE = bytes(a ^ b for a, b in zip(SALT_C, SALT_D))
HDR_AES = bytes([0x74, 0x63, 0x05, 0x10, 0x00, 0x00])
HDR_AES_PRIVATE = bytes([18, 57, 32, 32, 2, 3])

UG_HOST = "https://api.trae.cn"
OAUTH_HOST = "https://api.trae.com.cn"
EP_STATUS = UG_HOST + "/trae/api/v2/ug/checkin_credits/status"
EP_CLAIM = UG_HOST + "/trae/api/v2/ug/checkin_credits/claim"
EP_EXCHANGE = OAUTH_HOST + "/cloudide/api/v3/trae/oauth/ExchangeToken"
REQ_BODY = '{"req_source": 1}'
CODE_ALREADY = 9095
CODE_RATE = 9074
AUTH_FAIL = (1001, 1002, 401, 403)


def log(msg):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(os.path.join(LOG_DIR, "trae_checkin.log"), "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (stamp, msg))
    except Exception:
        pass
    print(msg)


def load_config():
    if not os.path.isfile(CONFIG_FILE):
        sys.exit("未找到 config.json，请先执行安装脚本或复制 config.example.json 为 config.json 后填写")
    with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
        return json.load(fh)


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=2)


def storage_candidates():
    home = os.path.expanduser("~")
    names = ("Trae CN", "TRAE SOLO CN", "TRAE SOLO", "Trae")
    sub = ("User", "globalStorage", "storage.json")
    cands = []
    appdata = os.environ.get("APPDATA") or os.path.join(home, "AppData", "Roaming")
    for n in names:
        cands.append(os.path.join(appdata, n, *sub))
    lib = os.path.join(home, "Library", "Application Support")
    for n in names:
        cands.append(os.path.join(lib, n, *sub))
    for base in (home, os.path.join(home, ".config")):
        for n in (".trae-cn", ".trae", "Trae CN", "TRAE SOLO CN"):
            cands.append(os.path.join(base, n, *sub))
    return cands


def find_storage_json():
    for p in storage_candidates():
        if os.path.isfile(p):
            return p
    return None


def decrypt_value(b64_value):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        sys.exit("解密 storage.json 需要 cryptography 库，请先安装：pip install cryptography")
    buf = base64.b64decode(b64_value)
    if len(buf) < 40:
        raise ValueError("凭据串长度异常")
    if buf[0:6] == HDR_AES:
        salt = SALT_AES
    elif buf[0:6] == HDR_AES_PRIVATE:
        salt = SALT_AES_PRIVATE
    else:
        raise ValueError("未知的加密类型，前 6 字节为 %s" % buf[0:6].hex())
    final_hash = hashlib.sha512(hashlib.sha512(buf[6:38]).digest() + salt).digest()
    key = final_hash[0:16]
    iv = final_hash[16:32]
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    decrypted = dec.update(buf[38:]) + dec.finalize()
    stored_hash = decrypted[0:64]
    plaintext = decrypted[64:]
    pad = plaintext[-1] if plaintext else 0
    if 1 <= pad <= 16:
        plaintext = plaintext[:-pad]
    else:
        plaintext = plaintext.rstrip(b"\x00").rstrip()
    if stored_hash != hashlib.sha512(plaintext).digest():
        raise ValueError("SHA-512 校验失败，解密结果不正确")
    return plaintext.decode("utf-8")


def load_credential(cfg):
    trae = cfg.get("trae", {})
    storage_path = (trae.get("storage_path") or "").strip()
    if not storage_path:
        storage_path = find_storage_json() or ""
    if storage_path and os.path.isfile(storage_path):
        with open(storage_path, "r", encoding="utf-8") as fh:
            storage = json.load(fh)
        enc = (storage.get(STORAGE_KEY) or "").strip()
        if not enc:
            raise ValueError("storage.json 中找不到 %s 字段" % STORAGE_KEY)
        if enc.startswith("{"):
            cred = json.loads(enc)
        else:
            cred = json.loads(decrypt_value(enc))
        log("凭据来源：storage.json（%s）" % storage_path)
        return cred
    refresh_token = (trae.get("refresh_token") or "").strip()
    if refresh_token:
        log("凭据来源：config.json 中的 refresh_token")
        return {"refreshToken": refresh_token}
    raise ValueError("没有可用的 TRAE 凭据，请在 config.json 中填写 storage_path 或 refresh_token")


def http_post(url, headers, body, timeout=20):
    req = urllib.request.Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)


def build_headers(token, device_id):
    headers = {
        "Authorization": "Cloud-IDE-JWT " + token,
        "Content-Type": "application/json",
        "X-User-Region": "CN",
        "User-Agent": "Trae/1.107.1",
    }
    if device_id:
        headers["x-device-id"] = device_id
    return headers


def refresh_token(refresh_token, client_id):
    body = json.dumps({
        "ClientID": client_id,
        "RefreshToken": refresh_token,
        "ClientSecret": "-",
        "UserID": "",
    })
    status, text = http_post(EP_EXCHANGE, {"Content-Type": "application/json", "User-Agent": "Trae/1.107.1"}, body)
    if status < 400 and status > 0:
        try:
            result = json.loads(text).get("Result") or {}
            token = result.get("Token")
            new_refresh = result.get("RefreshToken")
            if token:
                return token, new_refresh, None
        except Exception:
            pass
    return None, None, "刷新失败 HTTP %s %s" % (status, text[:200])


def check_status(token, device_id):
    status, text = http_post(EP_STATUS, build_headers(token, device_id), REQ_BODY)
    try:
        d = json.loads(text)
    except Exception:
        return None, None, None, None, -1, text
    code = d.get("code", -1)
    if status >= 400 or code not in (0, None):
        return None, None, None, None, code, text
    return bool(d.get("checked_in", False)), d.get("credits", 0), d.get("extra_credits", 0), bool(d.get("enable", False)), code, text


def do_claim(token, device_id):
    status, text = http_post(EP_CLAIM, build_headers(token, device_id), REQ_BODY)
    try:
        d = json.loads(text)
    except Exception:
        return -1, text[:120], None
    points = None
    data = d.get("data")
    if isinstance(data, dict):
        points = data.get("points")
    return d.get("code", -1), d.get("message") or text[:120], points


def main():
    cfg = load_config()
    trae = cfg.get("trae", {})
    client_id = (trae.get("client_id") or "en1oxy7wnw8j9n").strip()
    device_id = (trae.get("device_id") or "").strip()
    try:
        cred = load_credential(cfg)
    except Exception as e:
        log("读取凭据失败：%s" % e)
        return 1
    token = (cred.get("accessToken") or "").strip()
    rt = (cred.get("refreshToken") or "").strip()
    if not token and rt:
        log("没有 accessToken，尝试用 refresh_token 自动换取")
        token, new_refresh, err = refresh_token(rt, client_id)
        if not token:
            log("自动换取 accessToken 失败：%s" % err)
            return 1
        if new_refresh:
            trae["refresh_token"] = new_refresh
            save_config(cfg)
        log("accessToken 刷新成功")
    if not token:
        log("没有可用的 accessToken，请在 config.json 中填写 refresh_token 或 storage_path")
        return 1

    checked_in, credits, extra, enable, code, raw = check_status(token, device_id)
    if checked_in is None and code in (1001, 1002) and rt:
        log("token 已过期，尝试自动刷新")
        token, new_refresh, err = refresh_token(rt, client_id)
        if not token:
            log("自动刷新失败：%s" % err)
            return 1
        if new_refresh:
            trae["refresh_token"] = new_refresh
            save_config(cfg)
        checked_in, credits, extra, enable, code, raw = check_status(token, device_id)

    if checked_in is None:
        if code == CODE_RATE:
            log("服务端限流：参与用户太多（9074），请稍后重试或调整定时时间")
        else:
            log("查询签到状态失败：HTTP %s code=%s raw=%s" % (code, code, raw[:200]))
        return 1

    if checked_in:
        balance = (credits or 0) + (extra or 0)
        log("今日已签到，无需重复操作")
        log("当前额度：基础 %s + 额外 %s = 合计 %s" % (credits, extra, balance))
        return 0

    if not enable:
        log("签到功能未开放（enable=false），可能活动未开始")
        return 1

    claim_code, message, points = do_claim(token, device_id)
    if claim_code == 0:
        balance = (credits or 0) + (extra or 0)
        log("签到成功，本次获得 %s 额度" % (points if points is not None else "未知"))
        log("当前额度：基础 %s + 额外 %s = 合计 %s" % (credits, extra, balance))
        return 0
    if claim_code == CODE_ALREADY:
        log("服务端提示今日已签到（9095）")
        return 0
    if claim_code == CODE_RATE:
        log("服务端限流：参与用户太多（9074），请稍后重试或调整定时时间")
        return 1
    if claim_code in AUTH_FAIL and rt:
        log("token 失效，尝试刷新后重试")
        token, new_refresh, err = refresh_token(rt, client_id)
        if not token:
            log("自动刷新失败：%s" % err)
            return 1
        if new_refresh:
            trae["refresh_token"] = new_refresh
            save_config(cfg)
        claim_code, message, points = do_claim(token, device_id)
        if claim_code == 0:
            log("签到成功，本次获得 %s 额度" % (points if points is not None else "未知"))
            return 0
        log("刷新后仍失败：code=%s %s" % (claim_code, message))
        return 1
    log("签到失败：code=%s %s" % (claim_code, message))
    return 1


if __name__ == "__main__":
    sys.exit(main())
