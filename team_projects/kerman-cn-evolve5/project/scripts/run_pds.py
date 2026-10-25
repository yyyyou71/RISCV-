"""Shared license/sign-off helpers. Use cache_board_pds.py for CACHE3 implementation."""
import os


def license_path(explicit):
    if explicit: return str(explicit)
    # Prefer the user's corrected setting over an inherited machine-wide value.
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            value=winreg.QueryValueEx(key,'PANGO_LICENSE_FILE')[0]
            if value: return value
    except (OSError,ImportError): pass
    value=os.environ.get('PANGO_LICENSE_FILE')
    if value: return value
    raise RuntimeError('Set PANGO_LICENSE_FILE or supply --license-file with a valid PDS license')


def signoff_errors(cfg):
    missing=[k for k in ('board_revision_confirmed','bank_vccio_confirmed','uart_header_confirmed') if cfg.get(k) is not True]
    if not cfg.get('confirmation_evidence','').strip(): missing.append('confirmation_evidence')
    return missing


if __name__=="__main__":
    raise SystemExit("Use cache_board_pds.py --variant burst|word|uncached|selftest")
