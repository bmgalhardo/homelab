from proxmoxer import ProxmoxAPI
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    user: str
    password: str


settings = Settings()

proxmox = ProxmoxAPI(
    "proxmox_host", user=settings.user, password=settings.password, verify_ssl=False
)


