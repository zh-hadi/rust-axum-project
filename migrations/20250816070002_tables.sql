-- Add migration script here
-- UUID Extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- USERS TABLE
CREATE TABLE "users" (
    id UUID NOT NULL PRIMARY KEY DEFAULT (uuid_generate_v4()),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    password TEXT NOT NULL,
    email_verified BOOLEAN DEFAULT FALSE,
    pending_email VARCHAR(255),
    pending_email_token UUID,
    pending_email_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_users_email ON "users"(email);

-- WORKSPACES TABLE
CREATE TABLE "workspaces" (
    id UUID NOT NULL PRIMARY KEY DEFAULT (uuid_generate_v4()),
    name TEXT NOT NULL,
    owner_user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    invite_code VARCHAR(25) UNIQUE NOT NULL DEFAULT (
      substr(md5(random()::text || clock_timestamp()::text), 0, 26)
      ),
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (owner_user_id, name)
);

CREATE INDEX idx_workspaces_owner_user_id ON "workspaces"(owner_user_id);

-- ROLES
CREATE TABLE "roles" (
    id UUID NOT NULL PRIMARY KEY DEFAULT (uuid_generate_v4()),
    workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    UNIQUE(workspace_id, name)
);

CREATE INDEX idx_roles_workspace_id ON "roles"(workspace_id);

-- PERMISSIONS (GLOBAL)
CREATE TABLE "permissions" (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    description TEXT
);

-- ROLE-PERMISSIONS
CREATE TABLE "role_permissions" (
    role_id UUID REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE INDEX idx_role_permissions_role_id ON "role_permissions"(role_id);
CREATE INDEX idx_role_permissions_permission_id ON "role_permissions"(permission_id);

-- WORKSPACE USERS (JOIN)
CREATE TABLE "workspace_users" (
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
    role_id UUID REFERENCES roles(id) ON DELETE SET NULL,
    status TEXT DEFAULT 'active',
    PRIMARY KEY (user_id, workspace_id)
);

CREATE INDEX idx_workspace_users_user_id ON "workspace_users"(user_id);
CREATE INDEX idx_workspace_users_workspace_id ON "workspace_users"(workspace_id);


-- EMAIL VERIFICATIONS
CREATE TABLE email_verifications (
     user_id UUID REFERENCES users(id) ON DELETE CASCADE,
     token UUID UNIQUE NOT NULL,
     expires_at TIMESTAMPTZ NOT NULL,
     PRIMARY KEY (user_id)
);

CREATE INDEX idx_email_verifications_token ON email_verifications(token);

-- PASSWORD RESETS
CREATE TABLE password_resets (
     user_id UUID REFERENCES users(id) ON DELETE CASCADE,
     token UUID UNIQUE NOT NULL,
     expires_at TIMESTAMPTZ NOT NULL,
     PRIMARY KEY (user_id)
);

CREATE INDEX idx_password_resets_token ON password_resets(token);

INSERT INTO permissions (id, name, description) VALUES
    (gen_random_uuid(), 'update_workspace', 'Update workspace details'),
    (gen_random_uuid(), 'delete_workspace', 'Delete the workspace'),
    (gen_random_uuid(), 'manage_roles', 'Manage workspace roles'),
    (gen_random_uuid(), 'manage_permissions', 'Assign permissions to roles'),
    (gen_random_uuid(), 'invite_members', 'Invite new members to workspace'),
    (gen_random_uuid(), 'view_members', 'View workspace members'),
    (gen_random_uuid(), 'view_roles', 'View available roles'),
    (gen_random_uuid(), 'view_permissions', 'View available permissions'),
    (gen_random_uuid(), 'remove_members', 'Ability to remove members from the workspace'),
    (gen_random_uuid(), 'assign_roles_to_members', 'Ability to assign roles to workspace members');



CREATE OR REPLACE FUNCTION create_default_roles_for_workspace()
RETURNS TRIGGER AS $$
DECLARE
    admin_role_id UUID;
    manager_role_id UUID;
BEGIN
    -- 1. Create Admin and Manager roles
    INSERT INTO roles (workspace_id, name, description)
    VALUES
        (NEW.id, 'Admin', 'Workspace administrator with full permissions'),
        (NEW.id, 'Manager', 'Workspace manager with limited permissions');

    -- 2. Get The Roles IDs
    SELECT id INTO admin_role_id FROM roles WHERE workspace_id = NEW.id AND name = 'Admin';
    SELECT id INTO manager_role_id FROM roles WHERE workspace_id = NEW.id AND name = 'Manager';

    -- 3. Assign Permissions to Admin Role
    INSERT INTO role_permissions (role_id, permission_id)
    SELECT admin_role_id, id FROM permissions;

    -- 4. Assign Limited Permissions to Manager Role
    INSERT INTO role_permissions (role_id, permission_id)
    SELECT manager_role_id, id FROM permissions
    WHERE name IN ('view_members', 'view_roles', 'view_permissions', 'invite_members');

    -- 5. Insert workspace create into workspace_users as Admin
    INSERT INTO workspace_users (user_id, workspace_id, role_id, status)
    VALUES (NEW.owner_user_id, NEW.id, admin_role_id, 'active');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER create_default_roles_for_workspace
AFTER INSERT ON workspaces
FOR EACH ROW
EXECUTE FUNCTION create_default_roles_for_workspace();


CREATE OR REPLACE FUNCTION ensure_single_default_workspace()
RETURNS TRIGGER AS $$
DECLARE
    default_count INT;
BEGIN
    SELECT COUNT(*) INTO default_count
    FROM workspaces
    WHERE owner_user_id = NEW.owner_user_id
     AND is_default = TRUE;

    IF default_count > 0 THEN
        -- if the user already has a deafult, force this one to false
        NEW.is_default = FALSE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER ensure_single_default_workspace_trigger
BEFORE INSERT ON workspaces
FOR EACH ROW
EXECUTE FUNCTION ensure_single_default_workspace();