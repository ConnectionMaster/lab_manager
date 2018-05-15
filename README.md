[![License](license-apache-2.svg)](https://github.com/AVGTechnologies/lab_manager/blob/master/LICENSE)

# Lab Manager
Service providing REST API for various cloud providers.

## Status
The solution is currently in development.

The only supported cloud provider at the moment is _vmWare vSphere_.

## Endpoints
```
GET  /computes
POST /computes
GET  /computes/:id
DELETE /computes/:id
PUT /computes/:id/power_on
PUT /computes/:id/power_off
PUT /computes/:id/reboot

GET  /computes/:id/snapshots
POST /computes/:id/snapshots
GET  /computes/:id/snapshots/:id
POST /computes/:id/snapshots/:id/revert
```

## Development

### Setup environment
* you will need Linux dev machine with Ruby 2.2.2
* create file `config/database.yml` based on adjusted `config/database.yml.example`
* create file `config/lab_manager.yml` based on adjusted `config/lab_manager.yml.example`
* run `rake db:setup`

### Run app
* please run command `rerun rackup`
(you can install reran globally by: `rvm @global do gem install rerun`)

### Example usage
#### Create & poweron virtual machine (compute unit)
`curl -i -H 'Content-Type: application/json' --data '{"provider_name":"v_sphere","image":"TA_8x64"}' localhost:21000/computes/`
It returns id of the created compute.

#### Destroy compute with id 1
`curl -i -X DELETE localhost:21000/computes/1`

#### Create & power on virtual machine with custom name
`curl -i -H 'Content-Type: application/json' --data '{"provider_name":"v_sphere","image":"TA_8x64", "create_vm_options": {"name":"fooooooooo"}}' localhost:21000/computes/`

#### Create & power on virtual machine in custom folder
The folder must exist in advance!
`curl -i -H 'Content-Type: application/json' --data '{"provider_name":"v_sphere","image":"TA_8x64", "create_vm_options": {"dest_folder":"foo/bar/baz"}}' localhost:21000/computes/`

#### Create & power on full clone
`curl -i -H 'Content-Type: application/json' --data '{"provider_name":"v_sphere","image":"TA_8x64", "create_vm_options": {"linked_clone":false}}' localhost:21000/computes/`
