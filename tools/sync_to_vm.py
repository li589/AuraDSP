# -*- coding: utf-8 -*-
import os
import sys
import paramiko

FILES_TO_SYNC = [
    "README.md",
    "docs/40-回顾/插件健壮性治理与多通道拓扑优化-2026-11-05.md",
    "app/auradsp_app/lib/core/plugins/plugin_manager_slots.dart",
    "app/auradsp_app/lib/core/plugins/plugin_models.dart",
    "engine/plugins/api/plugin_host.h",
    "engine/plugins/driver/plugin_host_manager.cpp",
    "engine/plugins/driver/plugin_json.cpp",
    "engine/plugins/formats/clap/clap_instance.cpp",
    "engine/plugins/formats/vst2/vst2_instance.cpp",
    "engine/plugins/formats/vst2/vst2_metadata.cpp",
    "engine/plugins/formats/vst3/vst3_instance.cpp",
    "engine/plugins/platform/posix/host/plugin_host_client_posix.cpp",
    "engine/plugins/platform/posix/plugin_gui_x11.cpp",
    "engine/plugins/platform/posix/win32_compat.h",
    "engine/plugins/platform/win32/host/plugin_host_client.cpp",
    "engine/plugins/platform/win32/plugin_gui_win32.cpp",
    "test/smoke/test_iem_and_fabfilter.py",
]

def main():
    host = os.environ.get("VM_HOST", "192.168.204.130")
    user = os.environ.get("VM_USER", "li")
    password = os.environ.get("VM_PASS", "12345678")
    remote_base = "/home/li/Workspace/AuraDSP"
    local_base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(hostname=host, username=user, password=password, timeout=10)
    sftp = ssh.open_sftp()

    print(f"Syncing {len(FILES_TO_SYNC)} files to {host}:{remote_base}...")
    for rel_path in FILES_TO_SYNC:
        local_path = os.path.join(local_base, *rel_path.split("/"))
        remote_path = f"{remote_base}/{rel_path}"
        remote_dir = os.path.dirname(remote_path)
        
        # Ensure remote dir
        try:
            sftp.stat(remote_dir)
        except IOError:
            ssh.exec_command(f"mkdir -p '{remote_dir}'")
            
        sftp.put(local_path, remote_path)
        print(f"  [OK] {rel_path}")

    sftp.close()
    ssh.close()
    print("All files synced successfully.")

if __name__ == "__main__":
    main()
