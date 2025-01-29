#!/bin/bash
# Crée par SCHMITT Paul

# Variables d'environnement
PROXMOX_USER="your_proxmox_user" # Eg. root
PROXMOX_HOST="your_proxmox_IP_Address" # Eg. 192.168.0.10
REMOTE_STORAGE_NAME="your_proxmox_storage_name" # Eg. local-lvm

clear
echo -e "Bienvenue,\nAvant de continuer, veuillez vous assurer d'avoir le nom exacte de la machine virtuelle que vous souhaitez exporter sur Proxmox"
REMOTE_PROXMOX_POOL=$(ssh -T "$PROXMOX_USER"@"$PROXMOX_HOST" << EOF
ls /etc/pve/nodes
EOF
) # Execute le code à distance avec l'utilisation de EOF

echo -e "Voici les serveurs proxmox disponibles :\n"
for proxmox_server in $REMOTE_PROXMOX_POOL
do
	echo $proxmox_server
done
echo -e "\n"
read -p "Sur quel Proxmox souhaitez-vous créer la machine virtuelle (attention sensible à la casse) : "  proxmoxchoice
REMOTE_PROXMOX_EXISTING_VMS=$(ssh -T "$PROXMOX_USER"@"$PROXMOX_HOST" << EOF
ls /etc/pve/nodes/$proxmoxchoice/qemu-server
EOF
) # Lancement d'un script à distance via la commande ssh et le bloc EOF
echo -e "Voici les ID des machines virtuelles déjà prises :\n"
for proxmox_virtual_machine in $REMOTE_PROXMOX_EXISTING_VMS
do
	BASENAME="${proxmox_virtual_machine%.conf}" # Permet de remove l'extension .conf lors de l'affichage
	echo "$BASENAME"
done
echo -e "\n"
read -p "Veuillez choisir l'ID pour la futur machine virtuelle : " virtual_machine_id
read -p "Veuillez entrer le nom exacte de la machine virtuelle présente sur votre machine : " virtual_machine_name
echo -e "\n"
temp_path=/tmp/${virtual_machine_name}.ova
vboxmanage export "$virtual_machine_name" -o "$temp_path" # Export de la machine virtuelle en .ova
if [ $? -ne 0 ] # Vérifie l'exit code de la denière commande rentrée
then
	echo "Erreur d'exportation de la machine virtuelle vers /tmp"
	exit 1
fi
echo -e "Import réussi à $temp_path"
echo "Transfert de l'ova vers Proxmox"
scp "$temp_path" "$PROXMOX_USER@$PROXMOX_HOST:/tmp"
if [ $? -ne 0 ] # Vérifie l'exit code de la denière commande rentrée
then
	echo "Erreur d'exportation de l'ova vers le proxmox distant"
	exit 1
fi
echo "Export vers le proxmox distant réussi"
ssh "$PROXMOX_USER@$PROXMOX_HOST" << EOF
mkdir -p /tmp/ova-extraction
tar -xvf $temp_path -C /tmp/ova-extraction
DISK_FILE=\$(find /tmp/ova-extraction -name "*vmdk" | head -n 1)
if [ -z "\$DISK_FILE" ]
then
	echo "Erreur: Aucun disque trouvé sur le proxmox distant dans /tmp/ova-extraction"
	exit 1
fi
echo "Conversion du disque au format qcow2"
mkdir -pv /var/lib/vz/images/$virtual_machine_id
if [ -z "/var/lib/vz/images/$virtual_machine_id" ]
then
	echo "Répertoire non créé"
	exit 1
fi

qemu-img convert -f vmdk -O qcow2 \$DISK_FILE "/var/lib/vz/images/$virtual_machine_id/vm-$virtual_machine_id-disk-0.qcow2" 2>/dev/null
if [ $? -ne 0 ]
then
	echo "Erreur lors de la conversion du disque"
	exit 1
fi
echo "Création de la machine virtuelle dans $proxmoxchoice"
qm create $virtual_machine_id --name $virtual_machine_name --memory 4096 --cores 2 --net0 virtio,bridge=vmbr2 2>/dev/null
qm importdisk $virtual_machine_id /var/lib/vz/images/$virtual_machine_id/vm-$virtual_machine_id-disk-0.qcow2 $REMOTE_STORAGE_NAME 2>/dev/null
qm set $virtual_machine_id --scsihw virtio-scsi-pci --scsi0 $REMOTE_STORAGE_NAME:vm-$virtual_machine_id-disk-0 2>/dev/null
# Spécifier le boot order
qm set $virtual_machine_id --bootdisk scsi0 2>/dev/null
qm set $virtual_machine_id --boot c --bootdisk scsi0 2>/dev/null
echo "Importation de la machine virtuelle terminé !"
rm -rf /tmp/${virtual_machine_name}.ova /tmp/ova-extraction
echo "Suppression des fichiers temporaires distants"
EOF

echo "Suppression des fichiers locaux"
rm -f "$temp_path"

echo "Programme terminé !"
