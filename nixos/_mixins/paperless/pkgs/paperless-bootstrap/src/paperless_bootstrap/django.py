from __future__ import annotations

import os
from importlib import import_module
from pathlib import Path
from typing import Any

from paperless_bootstrap.bootstrap import Error, Repository, UserSpec, load_spec, reconcile

AI_WORKFLOW = "Fleet managed: Apply AI suggestions"
LEGACY_WORKFLOWS = ("Auto OCR with paperless-gpt", "Auto classify after paperless-gpt OCR")


class DjangoRepository(Repository):
    def __init__(self) -> None:
        self.user_model: Any = import_module("django.contrib.auth").get_user_model()
        self.group_model: Any = import_module("django.contrib.auth.models").Group
        self.email_model: Any = import_module("allauth.account.models").EmailAddress
        self.token_model: Any = import_module("rest_framework.authtoken.models").Token

    def ensure_group(self, name: str) -> None:
        self.group_model.objects.get_or_create(name=name)

    def reconcile_user(self, spec: UserSpec, password: str) -> None:
        desired: dict[str, object] = {
            "is_staff": spec.is_staff,
            "is_superuser": spec.is_superuser,
        }
        if spec.email:
            desired["email"] = spec.email
        user, _ = self.user_model.objects.get_or_create(
            username=spec.username,
            defaults=desired,
        )
        changed = False
        for field, value in desired.items():
            if getattr(user, field) != value:
                setattr(user, field, value)
                changed = True
        if not user.check_password(password):
            user.set_password(password)
            changed = True
        if changed:
            user.save()

    def reconcile_primary_email(self, username: str, email: str) -> None:
        user = self.user_model.objects.get(username=username)
        address, _ = self.email_model.objects.get_or_create(
            user=user,
            email=email,
            defaults={"verified": True, "primary": True},
        )
        self.email_model.objects.filter(user=user, primary=True).exclude(pk=address.pk).update(
            primary=False
        )
        changed = False
        for field, value in {"verified": True, "primary": True}.items():
            if getattr(address, field) != value:
                setattr(address, field, value)
                changed = True
        if changed:
            address.save()

    def reconcile_token(self, username: str, token: str) -> None:
        user = self.user_model.objects.get(username=username)
        existing = self.token_model.objects.filter(user=user).first()
        if existing is None:
            self.token_model.objects.create(user=user, key=token)
        elif existing.key != token:
            existing.delete()
            self.token_model.objects.create(user=user, key=token)

    def reconcile_ai_workflow(self, enabled: bool) -> None:
        models = import_module("documents.models")
        transaction = import_module("django.db.transaction")
        with transaction.atomic():
            if not enabled:
                models.Workflow.objects.filter(name=AI_WORKFLOW).update(enabled=False)
                return
            models.Workflow.objects.filter(name__in=LEGACY_WORKFLOWS).update(enabled=False)
            workflow, _ = models.Workflow.objects.get_or_create(name=AI_WORKFLOW)
            trigger = models.WorkflowTrigger(
                type=models.WorkflowTrigger.WorkflowTriggerType.DOCUMENT_ADDED
            )
            action_type = models.WorkflowAction.WorkflowActionType.APPLY_AI_SUGGESTIONS
            actions = [
                models.WorkflowAction(
                    type=action_type,
                    order=0,
                    ai_suggestion_fields=["title", "created", "correspondent"],
                    ai_create_missing=True,
                    ai_overwrite_existing=True,
                ),
                models.WorkflowAction(
                    type=action_type,
                    order=1,
                    ai_suggestion_fields=["document_type"],
                    ai_create_missing=False,
                    ai_overwrite_existing=True,
                ),
            ]
            reconcile_components(workflow.triggers, [trigger], retain_removed=False)
            # Queued tasks refer to action IDs even after a workflow is edited.
            reconcile_components(workflow.actions, actions, retain_removed=True)
            if not workflow.enabled or workflow.order != 0:
                workflow.enabled = True
                workflow.order = 0
                workflow.save(update_fields=["enabled", "order"])


def reconcile_component(component: Any, desired: Any) -> Any:
    fields = [field for field in desired._meta.concrete_fields if not field.primary_key]
    changed = component is None or any(
        getattr(component, field.attname) != getattr(desired, field.attname) for field in fields
    )
    if component is not None:
        changed = changed or any(
            getattr(component, field.name).exists() for field in desired._meta.many_to_many
        )
    if not changed:
        return component

    # Components may be shared with other workflows. Never change a shared one.
    if component is None or component.workflows.count() > 1:
        component = desired
        component.save()
    else:
        for field in fields:
            setattr(component, field.attname, getattr(desired, field.attname))
        component.save()
        for field in desired._meta.many_to_many:
            getattr(component, field.name).clear()
    return component


def reconcile_components(relation: Any, desired: list[Any], *, retain_removed: bool) -> None:
    existing = list(relation.order_by("pk"))
    components = [
        reconcile_component(existing[index] if index < len(existing) else None, component)
        for index, component in enumerate(desired)
    ]
    relation.set(components)
    if not retain_removed:
        desired[0].__class__.objects.filter(
            pk__in=[item.pk for item in existing if item.pk not in {c.pk for c in components}],
            workflows__isnull=True,
        ).delete()


def main() -> None:
    try:
        config_path = os.environ["PAPERLESS_BOOTSTRAP_CONFIG"]
    except KeyError as error:
        raise Error("PAPERLESS_BOOTSTRAP_CONFIG is not set") from error
    reconcile(DjangoRepository(), load_spec(Path(config_path)))
