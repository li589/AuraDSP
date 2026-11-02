import os
import sys
import paramiko

def run_vm(cmd):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    host = os.environ.get("VM_HOST", "192.168.204.130")
    user = os.environ.get("VM_USER", "li")
    password = os.environ.get("VM_PASS", "12345678")
    key_path = os.path.expanduser("~/.ssh/id_ed25519")
    
    connect_kwargs = {"hostname": host, "username": user, "timeout": 10}
    if os.path.exists(key_path):
        connect_kwargs["key_filename"] = key_path
    elif password:
        connect_kwargs["password"] = password
        
    ssh.connect(**connect_kwargs)
    stdin, stdout, stderr = ssh.exec_command(cmd)
    out = stdout.read().decode('utf-8', errors='replace')
    err = stderr.read().decode('utf-8', errors='replace')
    code = stdout.channel.recv_exit_status()
    ssh.close()
    if out:
        print(out, end='')
    if err:
        print('[STDERR]\n' + err, end='')
    return code

if __name__ == '__main__':
    cmd = ' '.join(sys.argv[1:]) if len(sys.argv) > 1 else 'hostname && uname -a'
    rc = run_vm(cmd)
    sys.exit(rc)
