# Ansible - Personal HomeLab

My personal ansible repository to configure my homelab. I'll try to make it as generic as possible so it can be easily cloned. However I do not recommend to clone it to use it as a base since it highly depends on my own network configuration (what machines I'm using, how I set their network configuration etc).

## My configuration

> [!NOTE]  
> I'm describing MY OWN setup, for MY OWN homelab. Then keep in mind that I do not intend to share this so people can reuse it. I'm openminded and open to discussions about improvement about this (especially about security or use of ansible), but don't try to ask for features. I also discourage the use of this repository: it would likely be more useful to make your own ansible repository for YOUR OWN homelab. Indeed, this is very likely that our infrastructure differ so I highly recommend you only take what might interest you as a source of inspiration. Below, the use of "you" will actually refers to the future me.

I'm currently running a very basic homelab. It contains only one mini-PC serving as a homeserver. It will handle every applications in the beginning, as long as it fits my needs. Thus the configuration could be done in one simple yaml file. But in order to make it easier to read, to maintain and to evolve I'm trying to get it well organised already.

Machines :

- Mini PC : HP EliteDesk 800 G2 (Intel Core i5 6500U - 8GB DDR4 - 256GB SSD)
- Modem (the one supplied by ISP)

Desired applications :

- Jellyfin

This configuration needs some basic setup, such as an OpenSSH server, security configuration (firewall, fail2ban etc) and docker.

## Setup the homelab

To setup the homelab with this ansible playbook you have to copy and edit the variables file:

```zsh
cp vars.example.yml vars.yml
nvim vars.yml
```

<table>
    <thead>
        <tr>
            <td>Variable</td>
            <td>Description</td>
            <td>Nullable</td>
            <td>Example</td>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td><code>authorized_users</code></td>
            <td>The list of users that are allowed to connect on the server using SSH</td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
authorized_users:
  - my_user
  - my_buddy
  - my_bestie</pre>
            </td>
        </tr>
        <tr>
            <td><code>remote_user</code></td>
            <td>User to actually use for the SSH connection Ansible will use</td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
remote_user: my_user</pre>
            </td>
        </tr>
        <tr>
            <td><code>ssh_port</code></td>
            <td>The SSH port that will used after the first run of Ansible. Considered a good practice not to use a common port like 22 or 2222.</td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
ssh_port: 2222 # CONSIDERED A BAD PRACTICE TO KEEP IT AT 22 OR 2222</pre>
            </td>
        </tr>
        <tr>
            <td><code>homeserver_host</code></td>
            <td>Very likely to evolve. For the moment I'm managing only one machine. But it might soon turn out that this is not enough. Then I guess I'll look for something that is more like a dictionnary or a map structure.<br/><br/>
            This represents the IP of the managed node.
            </td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
homeserver_host: 192.168.1.1 # CHANGE THIS FOR YOUR HOMESERVER LOCAL (OR REMOTE) IP ADDRESS</pre>
            </td>
        </tr>
        <tr>
            <td><code>docker_users</code></td>
            <td>The variable used to add users from managed node to the <code>docker</code> group</td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
docker_users:
  - my_user
  - your_user
  - his_user
  - her_user</pre>
            </td>
        </tr>
        <tr>
            <td><code>jellyfin_users</code></td>
            <td>The variable used to add users from managed node to the <code>jellyfin</code> group</td>
            <td><code>No</code></td>
            <td>
                <pre lang="yaml">---
jellyfin_users:
  - my_user
  - your_user
  - his_user
  - her_user</pre>
            </td>
        </tr>
    </tbody>
</table>

Once you edited the variables to your needs, let's create a pair of SSH private and public keys. If you already have keys, you can use them. To make is easy to use, you can copy the SSH public keys you want to allow in the servers with the role `ssh` in the `public_keys/ssh_keys` folder. Each public key should be named after the user it corresponds to.

For example, if I have 4 users to allow on a managed node, I'll have this structure, where each file is an actual SSH public key:

```plain
.
└── public_keys
    └── ssh_keys
        ├── her_user
        ├── his_user
        ├── my_user
        └── your_user
```

> [!CAUTION]
> Pay attention to the file you copy in the ssh_keys folder. Indeed, you do not want to copy your private SSH key. NEVER.

Once we have our variables and ssh public keys set up, let's look at the inventory file.

At the moment, the `inventory.yml` file only contains one node, which is our server:

```yaml
---
Homeservers:
  hosts:
    homeserver:
```

As said above, we only manage one node at this stage. The variables for each hosts are defined in the `host_vars/homeserver` file, which actually reuse variables set up just before.

Now let's review the `playbook.yml` file. We can see it defines one task, which is to install the different roles on the only server.

Once we made sure everything is fine, let's run ansible:

```bash
ansible-playbook playbook.yml -i inventory.yml
```

## Improvements

There's certainly a lot to say. This is my first attempt of using Ansible, thus I'm still discovering features and pratices to get the job done.

I guess the usecases will emerge and needed refactors will then appears more obviously.