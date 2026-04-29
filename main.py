import os
import time
import googleapiclient.discovery


def stop_vm(event, context):
    project = os.environ["PROJECT_ID"]
    zone = os.environ["ZONE"]
    vm_name = os.environ["VM_NAME"]
    ip_strategy = os.environ.get("IP_STRATEGY", "ephemeral")
    region = os.environ.get("REGION", "")
    static_ip_name = os.environ.get("STATIC_IP_NAME", "")

    print(f"Billing alert received — stopping {vm_name} in {zone} (strategy={ip_strategy})")
    compute = googleapiclient.discovery.build("compute", "v1")

    # Idempotency: skip if already stopped
    instance = compute.instances().get(
        project=project, zone=zone, instance=vm_name
    ).execute()
    status = instance.get("status")
    if status in ("TERMINATED", "STOPPING", "SUSPENDED", "SUSPENDING"):
        print(f"VM is already {status} — nothing to do")
        return

    # Stop the VM and wait for completion
    op = compute.instances().stop(
        project=project, zone=zone, instance=vm_name
    ).execute()
    print(f"Stop operation: {op.get('name')}")
    _wait_zone_op(compute, project, zone, op["name"])
    print("VM stopped")

    # Auto-release static IP to stay fully on free tier
    if ip_strategy == "static-auto" and static_ip_name and region:
        _release_static_ip(compute, project, region, static_ip_name)


def _wait_zone_op(compute, project, zone, op_name, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = compute.zoneOperations().get(
            project=project, zone=zone, operation=op_name
        ).execute()
        if result["status"] == "DONE":
            if "error" in result:
                raise RuntimeError(f"Operation failed: {result['error']}")
            return
        time.sleep(2)
    raise TimeoutError(f"Operation {op_name} did not complete in {timeout}s")


def _release_static_ip(compute, project, region, address_name):
    """Delete the named regional address to avoid idle-IP charges."""
    try:
        compute.addresses().get(
            project=project, region=region, address=address_name
        ).execute()
    except Exception as e:
        print(f"No static IP named {address_name} in {region} (or not accessible): {e}")
        return

    print(f"Releasing static IP {address_name} in {region}")
    op = compute.addresses().delete(
        project=project, region=region, address=address_name
    ).execute()
    print(f"Release operation: {op.get('name')}")
