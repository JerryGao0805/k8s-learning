"""每晚自动关机：stop 所有带 Project=<project> 标签、正在运行的 EC2 实例。

这是成本兜底措施：哪天忘了跑 lab-down.sh，最多也只浪费到半夜。

开关存放在 SSM Parameter Store 里（值为 on/off），用 scripts/autostop.sh 切换。
比如当晚要通宵做集群升级，就先 `./scripts/autostop.sh off`。
"""

import os

import boto3

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


def handler(event, context):
    switch = ssm.get_parameter(Name=os.environ["SWITCH_PARAM"])["Parameter"]["Value"]
    if switch.strip().lower() != "on":
        print(f"autostop switch is '{switch}', skipping tonight")
        return {"stopped": [], "skipped": True}

    paginator = ec2.get_paginator("describe_instances")
    ids = []
    for page in paginator.paginate(
        Filters=[
            {"Name": "tag:Project", "Values": [os.environ["PROJECT"]]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ]
    ):
        for reservation in page["Reservations"]:
            ids.extend(i["InstanceId"] for i in reservation["Instances"])

    if ids:
        ec2.stop_instances(InstanceIds=ids)
    print(f"stopped {len(ids)} instance(s): {ids}")
    return {"stopped": ids, "skipped": False}
